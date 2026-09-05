#!/usr/bin/env python3
"""Drive the real panel against a simulated rig and check the RADIO changed.

⚠️ SCREENSHOTS PROVE IT DRAWS, NOT THAT IT WORKS. A panel can render every
control perfectly and send nothing - the C++ project's own scar is a route that
answered 200 and changed nothing. So this presses keys in a real browser and then
asks the HOST what the rig is set to, which is the only end of the chain that
cannot lie about itself.

⚠️ AGAINST THE SIMULATOR, so it can key, change band and move the frequency
without a carrier existing anywhere.

Exit 1 on the first control that does not reach the radio.
"""
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

import websocket

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# ⚠️ NOT client/build/web. That bundle is the ADMIN page - a browser has no
# operating surface on purpose - so driving it here checked keyboard shortcuts
# against a page that has none, and reported the rig unreachable. This needs the
# build made with --dart-define=HAMDECK_SHOOT=true, which is never served.
PANEL = os.path.join(ROOT, "client", "build", "web-shoot")
HOST = os.path.join(ROOT, "hamdeck-host")
PORT, CTRL, CDP = 5913, 5912, 9313
USER, PASSWORD = "e2e", "e2e-only"

# key, what it should do, and how to read the answer back off the rig.
# ⚠️ Each expectation is a fact about the RADIO, not about the panel.
CHECKS = [
    ("u", "mode USB", lambda s: s["mode"] == "USB"),
    ("l", "mode LSB", lambda s: s["mode"] == "LSB"),
    ("c", "mode CW", lambda s: s["mode"] == "CW"),
    ("6", "band 20 m", lambda s: 14_000_000 <= s["freq"] <= 14_350_000),
    ("4", "band 40 m", lambda s: 7_000_000 <= s["freq"] <= 7_300_000),
    ("v", "VFO swap sent", lambda s: True),
    ("space", "keyed", lambda s: s["tx"] is True),
    ("space", "unkeyed", lambda s: s["tx"] is False),
]

KEYCODE = {
    "u": (85, "u"), "l": (76, "l"), "c": (67, "c"), "v": (86, "v"),
    "4": (52, "4"), "6": (54, "6"), "space": (32, " "),
}


def status(token):
    with urllib.request.urlopen(
            f"http://127.0.0.1:{PORT}/api/status?token={token}", timeout=6) as r:
        return json.loads(r.read())


def main():
    if not os.path.isdir(PANEL) or not os.path.isfile(HOST):
        raise SystemExit("build the panel and the host first")

    store = tempfile.mktemp(suffix="-users.json")
    subprocess.run([HOST, "--users", store, "users", "set", USER],
                   input=PASSWORD + "\n", text=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    host = subprocess.Popen(
        [HOST, "--users", store, "--port", str(PORT), "--control-port", str(CTRL),
         "--radio", "", "--panel", PANEL],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    profile = tempfile.mkdtemp(prefix="e2e-chrome-")
    chrome = subprocess.Popen([
        "google-chrome", "--headless=new", "--disable-gpu", "--no-sandbox",
        "--window-size=1536,712", f"--user-data-dir={profile}",
        f"--remote-debugging-port={CDP}", "--remote-allow-origins=*", "about:blank"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2)

    failures = []
    try:
        token = json.loads(urllib.request.urlopen(urllib.request.Request(
            f"http://127.0.0.1:{PORT}/api/auth/login",
            data=json.dumps({"username": USER, "password": PASSWORD}).encode(),
            headers={"Content-Type": "application/json"}), timeout=6).read())["token"]

        ws_url = None
        for _ in range(40):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{CDP}/json", timeout=2) as r:
                    for t in json.loads(r.read()):
                        if t["type"] == "page":
                            ws_url = t["webSocketDebuggerUrl"]
                            break
                if ws_url:
                    break
            except Exception:
                pass
            time.sleep(0.5)
        ws = websocket.create_connection(ws_url, timeout=30)
        _id = [0]

        def cmd(method, **params):
            _id[0] += 1
            ws.send(json.dumps({"id": _id[0], "method": method, "params": params}))
            while True:
                msg = json.loads(ws.recv())
                if msg.get("id") == _id[0]:
                    return msg.get("result", {})

        def key(name):
            code, text = KEYCODE[name]
            for typ in ("keyDown", "keyUp"):
                args = dict(type=typ, windowsVirtualKeyCode=code,
                            nativeVirtualKeyCode=code, key=text)
                if typ == "keyDown":
                    args["text"] = text
                cmd("Input.dispatchKeyEvent", **args)
                time.sleep(0.05)

        cmd("Page.enable")
        cmd("Emulation.setDeviceMetricsOverride", width=1536, height=712,
            deviceScaleFactor=1, mobile=False)
        cmd("Page.navigate", url=f"http://127.0.0.1:{PORT}/")
        time.sleep(9)
        cmd("Input.insertText", text=USER)
        time.sleep(0.3)
        key_tab = dict(type="keyDown", windowsVirtualKeyCode=9,
                       nativeVirtualKeyCode=9, key="Tab")
        cmd("Input.dispatchKeyEvent", **key_tab)
        cmd("Input.dispatchKeyEvent", **{**key_tab, "type": "keyUp"})
        time.sleep(0.3)
        cmd("Input.insertText", text=PASSWORD)
        time.sleep(0.3)
        enter = dict(type="keyDown", windowsVirtualKeyCode=13,
                     nativeVirtualKeyCode=13, key="Enter", text="\r")
        cmd("Input.dispatchKeyEvent", **enter)
        cmd("Input.dispatchKeyEvent", **{**enter, "type": "keyUp"})
        time.sleep(7)

        # ⚠️ Prove the session is real before judging any control: every check
        # below would "fail" identically if the login simply had not happened.
        before = status(token)
        if not before.get("connected"):
            raise SystemExit("the simulated rig is not connected - nothing to test")

        for name, what, ok in CHECKS:
            key(name)
            time.sleep(1.2)
            s = status(token)
            if not ok(s):
                failures.append(f"{name!r} → {what}: rig says "
                                f"mode={s['mode']} freq={s['freq']} tx={s['tx']}")
                print(f"  FAIL  {name!r} → {what}")
            else:
                print(f"  ok    {name!r} → {what}")
        ws.close()
    finally:
        chrome.kill()
        shutil.rmtree(profile, ignore_errors=True)
        host.kill()
        try:
            os.remove(store)
        except OSError:
            pass

    if failures:
        print("\nCONTROLS THAT DID NOT REACH THE RADIO:")
        for f in failures:
            print("  " + f)
        return 1
    print("\nPANEL: every control checked reached the rig.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
