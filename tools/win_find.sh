#!/usr/bin/env bash
# Find text on the Windows screen and print where it is: "<x> <y>".
#
# ⚠️ THIS REPLACES CLICKING BY ARITHMETIC. A dropdown row's position depends on
# which item is ALREADY selected - Flutter aligns the selected row with the
# button - and the menu is clamped to the screen when the selection is near the
# end of the list. Both of those broke a formula that looked obviously right:
# one run picked "Pause" while reporting it had picked F13, and the next missed
# the menu entirely. Read the screen, click what is actually there.
#
#   win_find.sh <regex>  [x1 y1 x2 y2]     prints the centre of the first match
#   WIN_FIND_LAST=1 win_find.sh ...         prints the centre of the LAST match
# Exits 1 and prints nothing when the text is not on screen.
set -euo pipefail
VMID="${WIN_TEST_VMID:-109}"
PVE="${WIN_TEST_PVE:-pve}"
PAT="${1:?text to find}"
X1="${2:-0}"; Y1="${3:-0}"; X2="${4:-1280}"; Y2="${5:-800}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ssh "$PVE" "echo 'screendump /tmp/find.ppm' | qm monitor $VMID" >/dev/null 2>&1
sleep 1
ssh "$PVE" "cat /tmp/find.ppm" > "$TMP/s.ppm" 2>/dev/null
python3 - "$TMP" "$PAT" "$X1" "$Y1" "$X2" "$Y2" <<'PY'
import os, re, subprocess, sys
from PIL import Image
tmp, pat = sys.argv[1], sys.argv[2]
x1, y1, x2, y2 = map(int, sys.argv[3:7])
S = 3  # ⚠️ upscale: tesseract reads this UI's 12px type badly at native size
im = Image.open(f"{tmp}/s.ppm").crop((x1, y1, x2, y2))
im = im.resize((im.width * S, im.height * S), Image.LANCZOS)
im.save(f"{tmp}/c.png")
tsv = subprocess.run(["tesseract", f"{tmp}/c.png", "stdout", "tsv"],
                     capture_output=True, text=True).stdout
rows = [l.split("\t") for l in tsv.splitlines()[1:] if l.strip()]
# Rebuild lines, because a match is usually a phrase and tesseract emits words.
lines = {}
for r in rows:
    if len(r) < 12 or not r[11].strip():
        continue
    key = tuple(r[2:6])          # page/block/par/line
    L, T, W, H = (int(r[i]) for i in (6, 7, 8, 9))
    e = lines.setdefault(key, {"text": [], "l": L, "t": T, "r": L + W, "b": T + H})
    e["text"].append(r[11])
    e["l"] = min(e["l"], L); e["t"] = min(e["t"], T)
    e["r"] = max(e["r"], L + W); e["b"] = max(e["b"], T + H)
rx = re.compile(pat, re.I)
hits = [e for e in sorted(lines.values(), key=lambda e: e["t"])
        if rx.search(" ".join(e["text"]))]
if not hits:
    sys.exit(1)
# ⚠️ Sometimes the row wanted is the LAST match, not the first - F9 and F12 carry
# the same warning text and only their position tells them apart, and OCR reads
# the digits badly enough ("F1i4" for F14) that matching on the number is not
# safe. Anchor on wording that is unique, and use position for the rest.
e = hits[-1] if os.environ.get("WIN_FIND_LAST") else hits[0]
cx = x1 + ((e["l"] + e["r"]) / 2) / S
cy = y1 + ((e["t"] + e["b"]) / 2) / S
print(f"{int(cx)} {int(cy)}")
PY
