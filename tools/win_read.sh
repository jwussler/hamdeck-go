#!/usr/bin/env bash
# Read text off the Windows screen, so a check can assert what is ACTUALLY there.
#
# ⚠️ THIS EXISTS BECAUSE A CHECK PASSED FOR THE WRONG REASON. win_drive.sh
# reported "the panel survived being given F13" after clicking a menu row that
# was not F13 at all - Flutter aligns the SELECTED item with the button, so every
# row's absolute position shifts with the current selection, and a fixed
# coordinate silently picks a different key. The app was fine; the test was
# lying. Clicking by coordinate is unavoidable here, so the outcome has to be
# read back rather than assumed.
#
#   win_read.sh <x1> <y1> <x2> <y2>     prints the text in that screen box
set -euo pipefail
VMID="${WIN_TEST_VMID:-109}"
PVE="${WIN_TEST_PVE:-pve}"
X1="${1:?x1}"; Y1="${2:?y1}"; X2="${3:?x2}"; Y2="${4:?y2}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ssh "$PVE" "echo 'screendump /tmp/read.ppm' | qm monitor $VMID" >/dev/null 2>&1
sleep 1
ssh "$PVE" "cat /tmp/read.ppm" > "$TMP/s.ppm" 2>/dev/null
python3 - "$TMP" "$X1" "$Y1" "$X2" "$Y2" <<'PY'
import subprocess, sys
from PIL import Image
tmp, x1, y1, x2, y2 = sys.argv[1], *map(int, sys.argv[2:6])
im = Image.open(f"{tmp}/s.ppm").crop((x1, y1, x2, y2))
# ⚠️ Upscaled 4x. Tesseract reads this UI's 12px type badly at native size and
# well at 4x - and a check that misreads is a check that fails at random.
im = im.resize((im.width * 4, im.height * 4), Image.LANCZOS)
im.save(f"{tmp}/c.png")
print(subprocess.run(["tesseract", f"{tmp}/c.png", "stdout"],
                     capture_output=True, text=True).stdout.strip())
PY
