#!/usr/bin/env bash
# Count the characters in a box on the Windows screen. Prints a number.
#
# ⚠️ FOR THE PASSWORD FIELD, WHERE "NOT EMPTY" WAS NOT ENOUGH. Counting ink only
# proves SOMETHING is in the box: a password truncated from eight characters to
# five - which is exactly what the first-three-characters-eaten bug produced -
# has plenty of ink and sails through, and then the login fails for a reason the
# check said was fine. Dots are evenly spaced, so count the GAPS instead: each
# run of ink columns separated by blank ones is one character.
#
#   win_glyphs.sh <x1> <y1> <x2> <y2>
set -euo pipefail
VMID="${WIN_TEST_VMID:-109}"
PVE="${WIN_TEST_PVE:-pve}"
X1="${1:?x1}"; Y1="${2:?y1}"; X2="${3:?x2}"; Y2="${4:?y2}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ssh "$PVE" "echo 'screendump /tmp/gly.ppm' | qm monitor $VMID" >/dev/null 2>&1
sleep 1
ssh "$PVE" "cat /tmp/gly.ppm" > "$TMP/s.ppm" 2>/dev/null
python3 - "$TMP" "$X1" "$Y1" "$X2" "$Y2" <<'PY'
import sys
from PIL import Image
tmp, x1, y1, x2, y2 = sys.argv[1], *map(int, sys.argv[2:6])
im = Image.open(f"{tmp}/s.ppm").convert("L").crop((x1, y1, x2, y2))
w, h = im.size
px = im.load()
col = [px[x, y] for x in range(w) for y in range(h)]
ground = max(set(col), key=col.count)
inked = [any(abs(px[x, y] - ground) > 40 for y in range(h)) for x in range(w)]
# one run of inked columns = one glyph
runs, prev = 0, False
for v in inked:
    if v and not prev:
        runs += 1
    prev = v
print(runs)
PY
