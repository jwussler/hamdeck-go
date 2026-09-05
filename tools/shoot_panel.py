#!/usr/bin/env python3
"""Photograph the panel in every state that matters, against a simulated rig.

⚠️ CHECKING A BUILT PANEL FOR A STRING NEEDS BOTH ENCODINGS. Dart stores a
string as one byte per character only while every character fits in Latin-1; one
em dash makes the whole string UTF-16 in the snapshot, and an ASCII grep then
reports a feature as MISSING from a build that contains it. See payload_has().

⚠️ LOOK AT IT BEFORE SHIPPING IT. Geometry, overlap, hierarchy and "does this
read at a glance" are not things to reason about - they are things to render and
inspect. The transmit bar covering the RIT controls during a tune survived
review, a build, a deploy and an install, and was found by the operator
recording his screen and uploading the video. Nobody should have to do that: the
panel runs headless here, against a rig that cannot transmit, in about a minute.

⚠️ THE KEYED STATE IS PART OF THE SET. Half the layout faults only exist while
transmitting - the meter changes role, the bar grows, the readout changes colour
- and checking that by keying a real radio is not a check worth making. The
simulator keys.

⚠️ AND NARROW WINDOWS ARE PART OF THE SET. The column count comes from the
width, so the width is a thing under test.

    tools/shoot_panel.py [outdir]

Needs: a built web panel (client/build/web), google-chrome, python websocket-client.
"""
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

import websocket

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PANEL = os.path.join(ROOT, "client", "build", "web")
HOST = os.path.join(ROOT, "hamdeck-host")
PORT, CTRL, CDP = 5911, 5910, 9311
USER, PASSWORD = "shoot", "shoot-only"

# name, window size, keyed, press "," for the settings surface
#
# ⚠️ SETUP IS IN THE SET. It holds the PTT key, both audio devices and the gains
# - the page most likely to run off the bottom of a window, and the one a
# screenshot of the operating surface would never show.
SHOTS = [
    ("operate-1536x712", (1536, 712), False, False),
    ("keyed-1536x712", (1536, 712), True, False),
    ("setup-1536x712", (1536, 712), False, True),
    ("operate-1100x800", (1100, 800), False, False),
    ("operate-760x900", (760, 900), False, False),
]


def payload_has(path, text):
    """Is this string in a built Flutter payload?

    ⚠️ BOTH ENCODINGS, ALWAYS. An ASCII-only grep said the whole global-PTT
    status machinery was absent from an installer that had it - because those
    strings contain an em dash, which pushes them to UTF-16 in the snapshot.
    A payload check that reports a present feature as missing gets ignored the
    third time it cries wolf.
    """
    blob = open(path, "rb").read()
    return blob.count(text.encode()) + blob.count(text.encode("utf-16-le"))


def api(token, path):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{PORT}{path}?token={token}", timeout=6) as r:
            return json.loads(r.read())
    except Exception as e:
        return {"error": str(e)}


class Browser:
    """A real browser, driven by keyboard only.

    ⚠️ NO CLICK COORDINATES. Flutter draws its fields on a canvas, so a click is
    a guess about pixel positions that breaks the moment the form gains a field -
    and a mistyped login looks exactly like a rejected one. The panel focuses the
    first field that needs typing, so this is type, tab, type, enter.
    """

    def __init__(self, size):
        self.profile = tempfile.mkdtemp(prefix="shoot-chrome-")
        self.proc = subprocess.Popen([
            "google-chrome", "--headless=new", "--disable-gpu", "--no-sandbox",
            "--hide-scrollbars", f"--window-size={size[0]},{size[1]}",
            f"--user-data-dir={self.profile}",
            f"--remote-debugging-port={CDP}", "--remote-allow-origins=*", "about:blank"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.ws, self._id = None, [0]
        for _ in range(40):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{CDP}/json", timeout=2) as r:
                    for t in json.loads(r.read()):
                        if t["type"] == "page":
                            self.ws = websocket.create_connection(
                                t["webSocketDebuggerUrl"], timeout=30)
                            break
                if self.ws:
                    break
            except Exception:
                pass
            time.sleep(0.5)
        if not self.ws:
            raise SystemExit("chrome never came up")
        self.size = size

    def cmd(self, method, **params):
        self._id[0] += 1
        self.ws.send(json.dumps({"id": self._id[0], "method": method, "params": params}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == self._id[0]:
                return msg.get("result", {})

    def key(self, code, name, text=None):
        for typ in ("keyDown", "keyUp"):
            args = dict(type=typ, windowsVirtualKeyCode=code,
                        nativeVirtualKeyCode=code, key=name)
            if text and typ == "keyDown":
                args["text"] = text
            self.cmd("Input.dispatchKeyEvent", **args)
            time.sleep(0.05)

    def login(self, url):
        self.cmd("Page.enable")
        # ⚠️ Pin the viewport. The window size and the viewport are not the same
        # number, and a layout photographed at a size nobody uses proves nothing.
        self.cmd("Emulation.setDeviceMetricsOverride", width=self.size[0],
                 height=self.size[1], deviceScaleFactor=1, mobile=False)
        self.cmd("Page.navigate", url=url)
        time.sleep(9)
        self.cmd("Input.insertText", text=USER)
        time.sleep(0.3)
        self.key(9, "Tab")
        time.sleep(0.3)
        self.cmd("Input.insertText", text=PASSWORD)
        time.sleep(0.3)
        self.key(13, "Enter", "\r")
        time.sleep(7)

    def shot(self, path):
        data = self.cmd("Page.captureScreenshot", format="png")["data"]
        open(path, "wb").write(base64.b64decode(data))

    def close(self):
        try:
            self.ws.close()
        except Exception:
            pass
        self.proc.kill()
        shutil.rmtree(self.profile, ignore_errors=True)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "shots")
    os.makedirs(out, exist_ok=True)
    if not os.path.isdir(PANEL):
        raise SystemExit(f"no built panel at {PANEL} - run: cd client && flutter build web --release")
    if not os.path.isfile(HOST):
        raise SystemExit(f"no host binary at {HOST} - run: go build ./cmd/hamdeck-host")

    store = tempfile.mktemp(suffix="-users.json")
    subprocess.run([HOST, "--users", store, "users", "set", USER],
                   input=PASSWORD + "\n", text=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    # ⚠️ --radio "" is the simulator: it answers every control route and it
    # cannot put anything on the air.
    host = subprocess.Popen(
        [HOST, "--users", store, "--port", str(PORT), "--control-port", str(CTRL),
         "--radio", "", "--panel", PANEL],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2)
    try:
        token = json.loads(urllib.request.urlopen(urllib.request.Request(
            f"http://127.0.0.1:{PORT}/api/auth/login",
            data=json.dumps({"username": USER, "password": PASSWORD}).encode(),
            headers={"Content-Type": "application/json"}), timeout=6).read())["token"]

        for name, size, keyed, setup in SHOTS:
            api(token, "/api/ptt/on" if keyed else "/api/ptt/off")
            b = Browser(size)
            try:
                b.login(f"http://127.0.0.1:{PORT}/")
                if setup:
                    b.key(188, ",", ",")
                    time.sleep(2)
                path = os.path.join(out, f"{name}.png")
                b.shot(path)
                print(f"  {path}")
            finally:
                b.close()
        api(token, "/api/ptt/off")
    finally:
        host.kill()
        try:
            os.remove(store)
        except OSError:
            pass
    print(f"\n{len(SHOTS)} shots in {out} - LOOK AT THEM before shipping the panel.")


if __name__ == "__main__":
    main()
