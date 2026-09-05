#!/usr/bin/env bash
# How much ink is in a box on the Windows screen? Prints a pixel count.
#
# ⚠️ THIS EXISTS FOR THE PASSWORD FIELD. Every other field can be read back with
# OCR and retyped when wrong; a password is dots, so a box that silently stayed
# EMPTY looked exactly like a box that was filled - and the run carried on and
# blamed the panel for "still being on the login screen". Dots are ink. Count it.
#
#   win_ink.sh <x1> <y1> <x2> <y2>
set -euo pipefail
VMID="${WIN_TEST_VMID:-109}"
PVE="${WIN_TEST_PVE:-pve}"
X1="${1:?x1}"; Y1="${2:?y1}"; X2="${3:?x2}"; Y2="${4:?y2}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ssh "$PVE" "echo 'screendump /tmp/ink.ppm' | qm monitor $VMID" >/dev/null 2>&1
sleep 1
ssh "$PVE" "cat /tmp/ink.ppm" > "$TMP/s.ppm" 2>/dev/null
python3 - "$TMP" "$X1" "$Y1" "$X2" "$Y2" <<'PY'
import sys
from PIL import Image
tmp, x1, y1, x2, y2 = sys.argv[1], *map(int, sys.argv[2:6])
im = Image.open(f"{tmp}/s.ppm").convert("L").crop((x1, y1, x2, y2))
px = list(im.getdata())
ground = max(set(px), key=px.count)          # the field's own background
print(sum(1 for p in px if abs(p - ground) > 40))
PY
