#!/usr/bin/env bash
# Install a HamDeck Windows build on the test VM and drive it, headless.
#
# ⚠️ THIS IS THE OTHER HALF OF preflight.sh. That one proves the code; this one
# proves the ARTEFACT a Windows operator actually receives - the installer runs,
# the app starts, the tray appears, and a PTT key can be assigned without the
# window dying. Every one of tonight's bugs lived in that gap: they were in the
# native plugins and the installed app, which no headless browser can reach.
#
# ⚠️ AUDIO IS THE ONE THING THIS CANNOT JUDGE. The VM has no USB codec, and over
# RDP the sound is redirected to whoever is looking. Receive and transmit levels
# must still be proved on the station.
#
#   tools/win_test.sh path/to/HamDeck-Panel-Windows-Setup.exe
#
# Needs: VM 109 up, OpenSSH answering as the local account (see win_provision).
set -uo pipefail

VM_HOST="${WIN_TEST_HOST:-192.168.40.171}"
VM_USER="${WIN_TEST_USER:-jwussler}"
EXE="${1:?usage: win_test.sh <installer .exe>}"
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 $VM_USER@$VM_HOST"
OUT="${2:-/tmp/win-test}"
mkdir -p "$OUT"

fail() { echo "  FAIL  $1"; FAILED=1; }
ok()   { echo "  ok    $1"; }
FAILED=0

echo "== copy the installer"
scp -q "$EXE" "$VM_USER@$VM_HOST:C:/Users/$VM_USER/Setup.exe" || { fail "copy"; exit 1; }
ok "copied $(basename "$EXE")"

echo "== install it the way an operator would, but silently"
# ⚠️ /VERYSILENT is Inno Setup's own switch. A test that clicks through the
# wizard by hand proves the wizard, not the payload - and cannot run unattended.
$SSH 'powershell -NoProfile -Command "Start-Process -Wait -FilePath C:\Users\'"$VM_USER"'\Setup.exe -ArgumentList \"/VERYSILENT\",\"/SUPPRESSMSGBOXES\",\"/NORESTART\"; exit 0"' \
    && ok "installer returned" || fail "installer did not return cleanly"

echo "== is it actually on disk where the operator will look for it"
$SSH 'powershell -NoProfile -Command "if (Test-Path \"$env:LOCALAPPDATA\Programs\HamDeck Panel\hamdeck_panel.exe\") { exit 0 } elseif (Test-Path \"C:\Program Files\HamDeck Panel\hamdeck_panel.exe\") { exit 0 } else { exit 1 }"' \
    && ok "the executable is installed" || fail "installed, but the .exe is not where it should be"

echo "== start it, and see whether it is still alive thirty seconds later"
# ⚠️ THIRTY SECONDS, not one. A Flutter app that throws on its first frame exits
# a moment after starting, and a check that looks immediately calls that a pass.
$SSH 'powershell -NoProfile -Command "
  $exe = @(\"$env:LOCALAPPDATA\Programs\HamDeck Panel\hamdeck_panel.exe\",\"C:\Program Files\HamDeck Panel\hamdeck_panel.exe\") | Where-Object { Test-Path $_ } | Select-Object -First 1
  Start-Process $exe; Start-Sleep -Seconds 30
  if (Get-Process hamdeck_panel -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"' \
    && ok "still running after 30 s" || fail "the app died after starting"

echo "== photograph the desktop, because 'running' is not 'drawing'"
$SSH 'powershell -NoProfile -Command "
  Add-Type -AssemblyName System.Windows.Forms,System.Drawing
  $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
  $bmp.Save(\"$env:TEMP\hamdeck-shot.png\")"' >/dev/null 2>&1
scp -q "$VM_USER@$VM_HOST:C:/Users/$VM_USER/AppData/Local/Temp/hamdeck-shot.png" "$OUT/" 2>/dev/null \
    && ok "screenshot at $OUT/hamdeck-shot.png" || fail "could not photograph the desktop"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "WINDOWS: the installer runs, the app starts and stays up. LOOK AT THE SHOT."
    exit 0
fi
echo "WINDOWS BUILD IS NOT SHIPPABLE - see the failures above."
exit 1
