#!/usr/bin/env python3
"""Prove the SHIPPED web bundle carries no operating surface.

⚠️ "A browser is admin only" is a claim about a compiled artifact, not about a
source file. The operating surface is excluded by a const `bool.fromEnvironment`
that the compiler folds and tree-shakes - which is the right mechanism, and is
also exactly the kind of thing that silently stops working when somebody
references the widget from a path the folding cannot reach. So this greps the
real main.dart.js.

⚠️ AND IT GREPS BOTH ENCODINGS. Dart stores a string one byte per character only
while every character fits in Latin-1; a single em dash makes the whole string
UTF-16 in the snapshot and an ASCII grep then reports a string as absent from a
build that contains it. That trap has already cost a night here.

    tools/check_web_is_admin_only.py [client/build/web]
"""
import sys
from pathlib import Path

BUNDLE = Path(sys.argv[1] if len(sys.argv) > 1 else "client/build/web")
main_js = BUNDLE / "main.dart.js"
if not main_js.exists():
    print(f"no web build at {main_js} - run: flutter build web --release")
    sys.exit(1)

blob = main_js.read_bytes()


def present(needle: str) -> bool:
    return needle.encode("latin-1", "ignore") in blob or needle.encode("utf-16-le") in blob


# Strings that exist ONLY on the operating surface. If any of these is in the
# bundle, a browser can be made to key a transmitter.
OPERATING = [
    "TUNE",
    "MIC OFF AIR",
    "TUNING STEP",
    "scroll or click a digit to tune",
    "no tuner configured on this host",
]
# Strings that must be there, or the page is not the admin page at all - an
# empty bundle would otherwise "pass" the check above.
ADMIN = [
    "KILL TRANSMIT",
    "WHO IS SIGNED IN",
    "station admin",
]

leaked = [s for s in OPERATING if present(s)]
missing = [s for s in ADMIN if not present(s)]

if leaked or missing:
    print("THE WEB BUNDLE IS NOT ADMIN-ONLY - refusing:")
    for s in leaked:
        print(f"  - operating surface leaked into the browser build: {s!r}")
    for s in missing:
        print(f"  - the admin page is missing from the build: {s!r}")
    sys.exit(1)

print("web: admin only - no operating surface in the browser bundle")
