#!/usr/bin/env python3
"""Every route on the dashboard listener must need a session, except a named few.

⚠️ THIS IS A GATE, NOT A REPORT. Eleven routes on the station were answering 200
with no credential at all - what hardware the rig has, whether transmit was
locked down, whether it was recording, its power ceilings, and the entire route
inventory. Each one reads harmless alone; together they are a survey of
somebody's station handed to anyone who can reach the port. None of them was
found by reading the code - they were found by ASKING the host without a token,
which is what this does.

⚠️ IT IS SAFE TO RUN AGAINST THE LIVE STATION. Every call here is made WITHOUT a
session, so a route that is doing its job does nothing and answers 401. A route
that answers anything else is the finding.

⚠️ AND IT MUST BE ABLE TO FAIL. Take the guard off any route below and this
prints it and exits 1; that is the only evidence that a passing run means
anything. Proved that way on 09/04/2026.

Usage: tools/check_auth.py <base-url> [user password]
       with credentials it also checks the gated routes still ANSWER for a
       session, so "everything is 401" cannot be mistaken for a pass.
"""
import json
import os
import sys
import urllib.error
import urllib.request

# ⚠️ THE ONLY ROUTES ALLOWED TO ANSWER A STRANGER, and why each one is here.
# Anything added to this list is a decision somebody has to defend in review.
OPEN_ON_PURPOSE = {
    "/api/health": "how you ask 'is the host up' without holding a credential",
    "/api/auth/login": "the door itself",
    "/api/auth/logout": "acts only on the caller's own token",
    "/api/auth/status": "says whether a session exists; carries nothing about the station",
}

# Reading these with a session is harmless: they change nothing and key nothing.
# ⚠️ Deliberately NOT every route - a positive check that keyed the transmitter
# to prove authentication works would be a cure worse than the disease.
SAFE_WITH_SESSION = [
    "/api/routes", "/api/remote/status", "/api/record/status",
    "/api/tune/tgxl/status", "/api/admin/lockdown/status",
    "/api/power/max", "/api/power/limit",
    "/api/diversity/status", "/api/vfo-lock/status",
    "/api/status", "/api/meters",
]


def get(url):
    try:
        with urllib.request.urlopen(url, timeout=6) as r:
            return r.status, r.read().decode()[:200]
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:200]
    except Exception as e:
        return 0, str(e)


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
    base = sys.argv[1].rstrip("/")
    user = sys.argv[2] if len(sys.argv) > 2 else None
    password = resolve_password(sys.argv[3] if len(sys.argv) > 3 else "") if user else None

    token = None
    if user:
        req = urllib.request.Request(
            f"{base}/api/auth/login",
            data=json.dumps({"username": user, "password": password}).encode(),
            headers={"Content-Type": "application/json"})
        token = json.loads(urllib.request.urlopen(req, timeout=6).read())["token"]

    # The inventory comes from the host itself, so a route added tomorrow is
    # checked tomorrow without anybody remembering to add it here.
    if token:
        # ⚠️ Read this one in FULL. get() truncates bodies to 90-odd characters
        # so a leaked reply prints as one readable line - which is right for a
        # finding and useless for parsing the inventory out of.
        with urllib.request.urlopen(f"{base}/api/routes?token={token}", timeout=6) as r:
            routes = sorted(json.loads(r.read().decode())["routes"])
    else:
        print("no credentials given: checking only the routes this file knows about")
        routes = sorted(set(SAFE_WITH_SESSION) | set(OPEN_ON_PURPOSE))

    leaked = []
    for r in routes:
        if r.startswith("/ws"):
            continue  # a websocket answers 426 to a plain GET; that is correct
        if r in OPEN_ON_PURPOSE:
            continue
        code, body = get(f"{base}{r}")
        # ⚠️ 401 is the pass. A 404, a 405 or a connection error is NOT: they
        # mean the check never reached the handler, and "it did not answer 200"
        # would quietly count that as secure.
        if code != 401:
            leaked.append((r, code, body.strip()[:90]))

    silent = []
    if token:
        for r in SAFE_WITH_SESSION:
            code, _ = get(f"{base}{r}?token={token}")
            if code != 200:
                silent.append((r, code))

    print(f"routes checked: {len(routes)}   open on purpose: {len(OPEN_ON_PURPOSE)}")
    for r, why in OPEN_ON_PURPOSE.items():
        code, _ = get(f"{base}{r}")
        print(f"  open  {r:24s} {code}  ({why})")

    if leaked:
        print(f"\nANSWERED WITHOUT A SESSION ({len(leaked)}):")
        for r, c, b in leaked:
            print(f"  {r}  HTTP {c}  {b}")
    if silent:
        print(f"\nREFUSED A VALID SESSION ({len(silent)}) - the gate is on too tight:")
        for r, c in silent:
            print(f"  {r}  HTTP {c}")
    if leaked or silent:
        return 1
    print("\nAUTH: every route needs a session, and every gated route still answers one.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
