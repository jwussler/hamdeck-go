#!/usr/bin/env bash
# Drive the installed Windows panel against a simulated rig, and photograph it.
#
# ⚠️ INSTALLING IS NOT USING. tools/win_test.sh proves the artifact installs and
# starts; this proves an operator can do something with it. Both of tonight's
# worst bugs - the crash on choosing a PTT key, and an app that cannot launch on
# a clean machine - were only visible on the far side of "it built".
#
# ⚠️ THE PTT KEY IS PRESSED BY THE HYPERVISOR, not by the app's own process. A
# system-wide hotkey is exactly the thing you cannot test from inside the
# program: sending it to yourself proves nothing about whether Windows routed it
# to you. `qm monitor sendkey f13` is a keystroke at the virtual keyboard - the
# same path a footswitch takes.
#
#   tools/win_drive.sh [outdir]
set -uo pipefail
cd "$(dirname "$0")/.."

VM_HOST="${WIN_TEST_HOST:-192.168.40.168}"
VM_USER="${WIN_TEST_USER:-jwussler}"
KEY="${WIN_TEST_KEY:-$HOME/.ssh/vm_admin}"
VMID="${WIN_TEST_VMID:-109}"
PVE="${WIN_TEST_PVE:-pve}"
SHACK="${WIN_TEST_SHACK:-192.168.40.60}"
PORT=5920
OUT="${1:-/tmp/win-drive}"
SSH="ssh -i $KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 $VM_USER@$VM_HOST"
mkdir -p "$OUT"
FAILED=0
fail() { echo "  FAIL  $1"; FAILED=1; }
ok()   { echo "  ok    $1"; }

shot() { # shot <name>
    ssh "$PVE" "echo 'screendump /tmp/drive.ppm' | qm monitor $VMID" >/dev/null 2>&1
    sleep 1
    ssh "$PVE" "cat /tmp/drive.ppm" > "$OUT/$1.ppm" 2>/dev/null
    python3 -c "from PIL import Image; Image.open('$OUT/$1.ppm').save('$OUT/$1.png')" 2>/dev/null
    rm -f "$OUT/$1.ppm"
}
key() { ssh "$PVE" "echo 'sendkey $1' | qm monitor $VMID" >/dev/null 2>&1; sleep "${2:-1}"; }

echo "== a simulated rig on shack, so the link is a real network"
# ⚠️ NOT ON THE WINDOWS BOX. A panel talking to a host on its own loopback tests
# neither the network nor the address handling - and the address box is where
# the last two UI faults were found.
pkill -f "hamdeck-host --users /tmp/windrive" 2>/dev/null
echo 'windrive' | ./hamdeck-host --users /tmp/windrive-users.json users set drive >/dev/null 2>&1
./hamdeck-host --users /tmp/windrive-users.json --port $PORT --control-port $((PORT-1)) \
    --radio "" >/tmp/windrive-host.log 2>&1 &
sleep 2
curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && ok "simulator up on $SHACK:$PORT" || fail "simulator did not start"

echo "== seed the settings the operator would have typed once"
# ⚠️ SEEDED, NOT TYPED. shared_preferences is a real file; writing it is exactly
# what the app does after a successful login, and it makes the drive
# deterministic instead of depending on canvas coordinates. The PASSWORD is
# still typed, because the app deliberately never stores one.
$SSH "powershell -NoProfile -Command \"
  \\\$d = Join-Path \\\$env:APPDATA 'com.wa0o.hamdeck_panel'
  New-Item -ItemType Directory -Force -Path \\\$d | Out-Null
  @{
    'flutter.host' = 'http://$SHACK:$PORT'
    'flutter.username' = 'drive'
    'flutter.ptt_key' = 'F13'
    'flutter.ptt_hold' = \\\$true
    'flutter.step' = 100
  } | ConvertTo-Json | Set-Content -Path (Join-Path \\\$d 'shared_preferences.json') -Encoding utf8
  'seeded'\"" >/dev/null 2>&1 && ok "settings seeded" || fail "could not seed settings"

echo "== launch it in the operator's session"
$SSH 'powershell -NoProfile -Command "Get-Process hamdeck_panel -ErrorAction SilentlyContinue | Stop-Process -Force"' >/dev/null 2>&1
$SSH 'powershell -NoProfile -Command "
  $dir = \"$env:LOCALAPPDATA\HamDeck Panel\"
  $act = New-ScheduledTaskAction -Execute (Join-Path $dir hamdeck_panel.exe) -WorkingDirectory $dir
  $pri = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
  Register-ScheduledTask -TaskName hamdeckdrive -Action $act -Principal $pri -Force | Out-Null
  Start-ScheduledTask -TaskName hamdeckdrive"' >/dev/null 2>&1
sleep 20
shot "01-connect"
$SSH 'powershell -NoProfile -Command "if (Get-Process hamdeck_panel -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"' \
    && ok "the panel is running and drawing (see 01-connect.png)" || { fail "the panel is not running"; }

echo "== log in: the address and account are remembered, so only the password is typed"
key "tab" 0.5      # into the password field, since USERNAME comes back filled
for c in w i n d r i v e; do key "$c" 0.15; done
key "ret" 8
shot "02-operate"

echo "== is the panel actually talking to the rig?"
LISTENERS=$(curl -s "http://127.0.0.1:$PORT/api/routes" -o /dev/null -w '%{http_code}')
SESSIONS=$(grep -c "POST /api/auth/login" /tmp/windrive-host.log 2>/dev/null || echo 0)
[ "$SESSIONS" -ge 1 ] && ok "the host saw a login from the Windows panel" \
    || fail "no login reached the simulator - the panel never connected"

echo "== the settings surface, and what it says about the PTT key"
key "comma" 3
shot "03-setup"

echo "== press F13 AT THE KEYBOARD, the way a footswitch would"
# ⚠️ Three presses, spaced. One is indistinguishable from a stray event; three
# with the count moving from 0 is the key actually reaching the app.
key "f13" 2; key "f13" 2; key "f13" 2
shot "04-after-f13"

echo
echo "shots in $OUT - LOOK AT 03 AND 04: the PTT line must go from"
echo "'claimed ... PRESS IT ONCE TO CONFIRM' to a confirmed mode with a press count."
pkill -f "hamdeck-host --users /tmp/windrive" 2>/dev/null
rm -f /tmp/windrive-users.json
[ "$FAILED" -eq 0 ] || exit 1
