#!/usr/bin/env python3
"""Compare this host's routes against the C++ host's, and CALL every one.

⚠️ COMPARING ROUTE INVENTORIES IS NOT COMPARING BEHAVIOUR. The C++ project's own
audit ticked /api/remote-tx/on because the route existed; it answered 200 and
changed nothing, and the status route beside it invented all three of its fields
so the two agreed with each other. So this does both halves:

  1. which C++ routes have no Go route at all - the checklist
  2. every Go route CALLED against the simulator, and its reply read

A route that answers 200 with an error body, or 500, is reported as broken even
though it exists. "Present" is not "working".

Usage: tools/parity.py <base-url> <user> <password> [--cpp <path to hamdeck-cpp>]
"""
import argparse
import json
import re
import os
import sys
import urllib.error
import urllib.request

# Routes that are deliberately not ported, with the reason. ⚠️ Anything not
# listed here and not implemented is a GAP, not a decision - the point of this
# file is that the difference is written down rather than remembered.
DELIBERATELY_ABSENT = {
    "/api/test": "a C++ debug route with no caller",
    "/api/session": "session shape differs; /api/auth/login covers it",
    "/api/session/reset": "same",
    "/api/build": "/api/health carries the version",
    "/api/profile": "no profiles on this host yet",
}


def cpp_routes(root):
    src = open(f"{root}/src/api.cpp").read()
    found = set()
    for pat in (r'generated\.push_back\(\{"(/api/[^"]+)"',
                r'GetPrefix\("(/api/[^"]+)"',
                r'\{"(/api/[^"]+)",\s*(?:set_mode|\[)',
                r'server\.(?:Get|Post)\("(/api/[^"]+)"'):
        found |= set(re.findall(pat, src))
    return found


def go_routes(base, token):
    """⚠️ ASK THE HOST, DO NOT GUESS FROM THE SOURCE. Reading Go literals with
    regular expressions missed one form and reported working routes as missing;
    /api/routes is built from the same registrations the server actually serves,
    so it cannot disagree with reality.

    ⚠️ IT NEEDS THE SESSION NOW. The route inventory used to answer anybody who
    could reach the port, which is a survey of somebody's station handed out for
    free; it is gated, so this logs in FIRST and asks with the token."""
    with urllib.request.urlopen(f"{base}/api/routes?token={token}", timeout=6) as r:
        return set(json.loads(r.read().decode())["routes"])


def call(base, path, token):
    url = f"{base}{path}?token={token}"
    try:
        with urllib.request.urlopen(url, timeout=6) as r:
            body = json.loads(r.read().decode())
            return r.status, body
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode())
        except Exception:
            return e.code, {}
    except Exception as e:
        return 0, {"message": str(e)}


# ⚠️ THE PASSWORD MAY COME FROM THE ENVIRONMENT, AND THAT IS THE POINT. An
# argument is in the shell history and visible in `ps` to every user on the box -
# the host's own CLI refuses a password flag for that reason, and a checker that
# demands one hands the problem straight back. Set HAMDECK_PASSWORD, or pass "-"
# to read it from stdin.
def resolve_password(arg):
    import getpass
    if arg == "-":
        return sys.stdin.readline().rstrip("\n")
    if arg:
        return arg
    env = os.environ.get("HAMDECK_PASSWORD")
    if env:
        return env
    return getpass.getpass("password: ")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("base")
    ap.add_argument("user")
    ap.add_argument("password", nargs="?", default="")
    ap.add_argument("--cpp", default="/home/ubuntu/hamdeck-cpp")
    ap.add_argument("--go", default="/home/ubuntu/hamdeck-go")
    ap.add_argument("--allow-control", action="store_true",
                    help="also call the routes that CHANGE the radio. Refused "
                         "unless the host reports a simulated rig.")
    a = ap.parse_args()

    # ⚠️ THE LOCK IS STRUCTURAL, NOT A WARNING. --allow-control against a host
    # holding a real serial port is refused here, not left to whoever is typing
    # at 1 a.m. to remember. It asks the HOST what it is rather than trusting
    # the address: "localhost" is a real radio for anybody running this on the
    # station box.
    if a.allow_control:
        with urllib.request.urlopen(f"{a.base}/api/health", timeout=6) as r:
            rig = json.loads(r.read().decode()).get("rig", "")
        if "simulated" not in rig:
            print(f"REFUSING --allow-control: this host has {rig!r}, not a simulator.\n"
                  "Control routes change the operator's station - antenna, filter, AGC,\n"
                  "which VFO is selected - and a checklist is not worth that.")
            return 1


    req = urllib.request.Request(
        f"{a.base}/api/auth/login",
        data=json.dumps({"username": a.user, "password": resolve_password(a.password)}).encode(),
        headers={"Content-Type": "application/json"})
    token = json.loads(urllib.request.urlopen(req, timeout=6).read())["token"]

    cpp, go = cpp_routes(a.cpp), go_routes(a.base, token)

    # ⚠️ A PREFIX ROUTE COVERS THE EXACT ONES UNDER IT. The C++ host registers
    # /api/mode/usb as its own entry AND a /api/mode/ prefix; counting the exact
    # ones as missing because this host only has the prefix reports 6 gaps that
    # do not exist, and a checklist that cries wolf stops being read.
    prefixes = [g for g in go if g.endswith("/")]

    def covered(r):
        return r in go or any(r.startswith(p) and r != p for p in prefixes)

    missing = sorted(r for r in cpp
                     if not covered(r) and r not in DELIBERATELY_ABSENT)


    # ⚠️ READ-ONLY BY DEFAULT, AND AGAINST A REAL RADIO THAT IS NOT NEGOTIABLE.
    #
    # This used to call everything that could not KEY the transmitter, on the
    # theory that the rest was harmless. It is not. Run against the live station
    # on 09/04/2026 it sent preamp on, notch on, monitor on, VFO lock on, split
    # on, filter to wide, cycled the ANTENNA and the AGC, selected VFO B, and
    # copied VFO A over VFO B - destroying whatever frequency was stored there.
    # The operator's panel then showed VFO A's frequency beside VFO B's mode,
    # which is a readout that disagrees with the radio it is drawn from.
    #
    # The C++ project wrote the rule down years ago - never probe a live rig
    # with a control route - and this file walked straight past it, because
    # "safe" had been defined as "does not transmit" rather than "does not
    # change the operator's station".
    #
    # So: only the reads below are called unless --allow-control is given, and
    # --allow-control REFUSES unless the host reports a simulated rig. A scope
    # lock the operator has to remember is not a lock.
    READS = ("/get", "/status", "/api/health", "/api/routes", "/api/meters",
             "/api/backend", "/api/audio", "/api/freq", "/api/freq-b",
             "/api/power/max", "/api/power/limit")
    UNSAFE = ("/ptt/", "/tune", "/cw/send", "/record", "/api/admin/")
    # ⚠️ Routes that END THE TEST'S OWN SESSION. Calling logout partway through
    # an alphabetical sweep turned 51 working routes into "login required" and
    # read exactly like an authentication regression. A checker must not break
    # the thing it is measuring.
    SELF_HARM = ("/api/auth/logout",)
    broken = []
    skipped = []
    called = 0
    for r in sorted(go):
        # ⚠️ A websocket answers 426 to a plain GET, which is CORRECT. Calling
        # them over HTTP measures nothing; they are exercised by
        # check_audio_roundtrip.sh, which actually speaks the protocol.
        if r.startswith("/ws"):
            continue
        if any(u in r for u in UNSAFE) or r.endswith("/"):
            continue
        # ⚠️ A control route is one that CHANGES THE RADIO, whether or not it
        # keys it. Skipped unless explicitly allowed against a simulator.
        is_read = any(r.endswith(k) or r == k for k in READS)
        if not is_read and not a.allow_control:
            skipped.append(r)
            continue
        if r in ("/api/auth/login",) or r in SELF_HARM:
            continue
        code, body = call(a.base, r, token)
        called += 1
        # ⚠️ "This host has no such hardware" is a CORRECT answer, not a fault.
        # A route that says supported/available false is doing its job; marking
        # it broken would mean the checklist could never come back clean on a
        # host without an amplifier, a tuner or a radio - and a gate that always
        # reports something stops being read.
        not_here = body.get("supported") is False or body.get("available") is False
        if code == 503 and not_here:
            continue
        if code != 200 or body.get("status") == "error":
            broken.append((r, code, body.get("message", "")))

    print(f"C++ routes: {len(cpp)}   Go routes: {len(go)}   called: {called}"
          + (f"   not called (they change the radio): {len(skipped)}" if skipped else ""))
    if missing:
        print(f"\nNOT PORTED ({len(missing)}):")
        for r in missing:
            print(f"  {r}")
    if broken:
        print(f"\nPRESENT BUT NOT WORKING ({len(broken)}):")
        for r, c, m in broken:
            print(f"  {r}  HTTP {c}  {m}")
    if not missing and not broken:
        print("\nPARITY: every C++ route has a Go route, and every Go route answers.")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
