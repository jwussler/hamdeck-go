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
# ⚠️ KEYBOARD FROM THE HYPERVISOR, POINTER FROM INSIDE THE SESSION. They are
# different tools for a reason that cost an evening: `qm monitor mouse_move` is
# always RELATIVE even though this guest's active pointer is an absolute HID
# tablet, and the tablet accumulates those deltas in an UNBOUNDED counter - one
# large negative move to "home" the pointer pushed it past -40000 and nothing
# could bring it back on screen. Clicks then landed nowhere, focus went
# elsewhere, and every login silently never happened while the script cheerfully
# typed a password into the Windows search box. Pointing is done by
# win_ui.ps1 (SetCursorPos in the operator's own session); the keyboard stays on
# the hypervisor because it works and needs nothing installed.
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

echo "== launch it in the operator's session"
# ⚠️ VIA A SCRIPT FILE THAT VERIFIES ITSELF. Registering the task with an inline
# PowerShell string over ssh failed silently, and Start-ScheduledTask on a task
# that does not exist returns nothing - so the test reported "the panel is not
# running" about an app nobody had asked to start.
scp -q -i "$KEY" tools/win_launch.ps1 "$VM_USER@$VM_HOST:C:/win_launch.ps1"
LAUNCH=$($SSH 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\win_launch.ps1 -TaskName hamdeckdrive' 2>&1 | tr -d '\r')
echo "$LAUNCH" | sed 's/^/     /'
shot "01-connect"
echo "$LAUNCH" | grep -q "^running after" \
    && ok "the panel started (see 01-connect.png)" || fail "the panel did not start"

echo "== log in by typing, the way an operator does"
# ⚠️ FOCUS FIRST, AND PROVE IT. Alt-tab raises the panel and one Tab puts the
# ring on the first field; typing before that put a station address into the
# Windows search box.
# ⚠️ TYPED, NOT SEEDED. The seeded preferences file assumed a storage path this
# app may not use on Windows, and a login that silently did not happen is
# indistinguishable from a panel that cannot connect. Typing is slower and it is
# the thing an operator actually does.
key "alt-tab" 2
key "tab" 1
type_in() { # type_in <text> - into the focused field, replacing what is there
    key "ctrl-a" 0.3; key "delete" 0.3
    bash "$(dirname "$0")/win_sendtext.sh" "$VMID" "$1"
    sleep 0.5
}
type_in "http://$SHACK:$PORT"
key "tab" 0.4; type_in "drive"
key "tab" 0.4; type_in "windrive"
shot "02-login-typed"
key "ret" 10
shot "03-operate"

echo "== is the panel actually talking to the rig?"
SESSIONS=$(grep -c "POST /api/auth/login" /tmp/windrive-host.log 2>/dev/null | head -1 | tr -dc '0-9')
SESSIONS=${SESSIONS:-0}
[ "$SESSIONS" -ge 1 ] && ok "the host saw a login from the Windows panel" \
    || fail "no login reached the simulator - the panel never connected"

echo "== the settings surface, and what it says about the PTT key"
key "comma" 3
shot "04-setup"

echo "== assign F13 - THE ACTION THAT KILLED THE APP"
# ⚠️ THIS IS THE REGRESSION TEST FOR THE CRASH. Choosing F13 aborted the process
# on a clean Windows 11 box: WER recorded exception c0000409 (__fastfail) inside
# hotkey_manager_windows_plugin.dll, a NATIVE abort that no Dart try/catch can
# ever catch. The panel now polls the key instead of registering it, and the
# only proof that holds is doing it again here and finding the app still alive.
#
# ⚠️ The menu is opened with the pointer and chosen with the KEYBOARD, because an
# open Flutter menu captures the mouse and SetCursorPos inside it gets overridden.
bash "$(dirname "$0")/win_click.sh" "click 383,320" >/dev/null 2>&1
sleep 1
bash "$(dirname "$0")/win_click.sh" "click 383,320" >/dev/null 2>&1   # first click only activates the window
sleep 1
shot "05-key-menu"
key "down" 0.6
key "ret" 3
ALIVE=$($SSH 'powershell -NoProfile -Command "(Get-Process hamdeck_panel -ErrorAction SilentlyContinue | Measure-Object).Count"' 2>/dev/null | tr -dc '0-9')
[ "${ALIVE:-0}" = "1" ] && ok "the panel survived being given F13" \
    || fail "THE PANEL DIED CHOOSING F13 - the crash is back"
shot "06-f13-assigned"

echo "== press F13 AT THE KEYBOARD, the way a footswitch would"
# ⚠️ Three presses, spaced. One is indistinguishable from a stray event; three
# with the count moving from 0 is the key actually reaching the app.
key "f13" 2; key "f13" 2; key "f13" 2
shot "07-after-f13"
KEYED=$(grep -cE "POST /api/(ptt|remote-tx)" /tmp/windrive-host.log 2>/dev/null | tr -dc '0-9')
[ "${KEYED:-0}" -ge 1 ] && ok "F13 reached the rig ($KEYED transmit calls)" \
    || fail "F13 changed nothing at the host - the key is not actually armed"

echo
echo "shots in $OUT - LOOK AT 06 AND 07: the PTT line must go from"
echo "'claimed ... PRESS IT ONCE TO CONFIRM' to a confirmed mode with a press count."
pkill -f "hamdeck-host --users /tmp/windrive" 2>/dev/null
rm -f /tmp/windrive-users.json
[ "$FAILED" -eq 0 ] || exit 1
