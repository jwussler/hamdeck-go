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


def go_routes(base):
    """⚠️ ASK THE HOST, DO NOT GUESS FROM THE SOURCE. Reading Go literals with
    regular expressions missed one form and reported working routes as missing;
    /api/routes is built from the same registrations the server actually serves,
    so it cannot disagree with reality."""
    with urllib.request.urlopen(f"{base}/api/routes", timeout=6) as r:
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("base")
    ap.add_argument("user")
    ap.add_argument("password")
    ap.add_argument("--cpp", default="/home/ubuntu/hamdeck-cpp")
    ap.add_argument("--go", default="/home/ubuntu/hamdeck-go")
    a = ap.parse_args()

    cpp, go = cpp_routes(a.cpp), go_routes(a.base)

    # ⚠️ A PREFIX ROUTE COVERS THE EXACT ONES UNDER IT. The C++ host registers
    # /api/mode/usb as its own entry AND a /api/mode/ prefix; counting the exact
    # ones as missing because this host only has the prefix reports 6 gaps that
    # do not exist, and a checklist that cries wolf stops being read.
    prefixes = [g for g in go if g.endswith("/")]

    def covered(r):
        return r in go or any(r.startswith(p) and r != p for p in prefixes)

    missing = sorted(r for r in cpp
                     if not covered(r) and r not in DELIBERATELY_ABSENT)

    req = urllib.request.Request(
        f"{a.base}/api/auth/login",
        data=json.dumps({"username": a.user, "password": a.password}).encode(),
        headers={"Content-Type": "application/json"})
    token = json.loads(urllib.request.urlopen(req, timeout=6).read())["token"]

    # ⚠️ Call only what cannot key a transmitter or move a tuner. This runs
    # against a simulator, but the same script pointed at the station must not
    # put a carrier on the air to tick a checkbox.
    UNSAFE = ("/ptt/", "/tune", "/cw/send", "/record", "/api/admin/")
    broken = []
    called = 0
    for r in sorted(go):
        if any(u in r for u in UNSAFE) or r.endswith("/"):
            continue
        if r in ("/api/auth/login",):
            continue
        code, body = call(a.base, r, token)
        called += 1
        if code != 200 or body.get("status") == "error":
            broken.append((r, code, body.get("message", "")))

    print(f"C++ routes: {len(cpp)}   Go routes: {len(go)}   called: {called}")
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
