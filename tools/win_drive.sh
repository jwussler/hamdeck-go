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
# ⚠️ AND REACHABLE FROM THE BOX UNDER TEST, which is not the same question.
# localhost answering proves the process is alive; it says nothing about whether
# the panel can get to it. A run once reported "the panel never connected" when
# the panel was fine and the host simply was not reachable from Windows - the
# check that passed was the wrong check.
REACH=$($SSH "powershell -NoProfile -Command \"(Test-NetConnection -ComputerName $SHACK -Port $PORT -InformationLevel Quiet)\"" 2>/dev/null | tr -d '\r' | tr -d ' ')
[ "$REACH" = "True" ] && ok "the Windows box can reach $SHACK:$PORT" \
    || fail "the Windows box CANNOT reach $SHACK:$PORT - nothing below this can pass"

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
# ⚠️ CLICK THE FIELD, DO NOT COUNT TABS. A freshly launched panel already
# autofocuses STATION, so an "alt-tab then one tab to be safe" put the address
# into USERNAME, the username into PASSWORD, and logged in as nobody - and the
# same script had worked minutes earlier against an instance that had been
# running long enough to lose focus. Focus is state; clicking sets it.
#
# ⚠️ Twice: on Windows the first click only activates the window.
click_station() {
    bash "$(dirname "$0")/win_click.sh" "click 650,314" >/dev/null 2>&1
    sleep 1
    bash "$(dirname "$0")/win_click.sh" "click 650,314" >/dev/null 2>&1
    sleep 1
}
click_station
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
# ever catch. The panel now polls the key instead of registering it, and the only
# proof that holds is doing it again here and finding the app still alive.
#
# ⚠️ AND THE SELECTION IS READ BACK, NEVER ASSUMED. Flutter aligns the SELECTED
# row with the button, so every row's absolute position depends on what is
# already chosen - a fixed coordinate picked "Pause" and this test cheerfully
# reported that the panel had survived being given F13. It had survived being
# given something else. Clicking by coordinate is the only option available, so
# the outcome gets OCR'd off the screen and the step fails if it is wrong.
KEY_FIELD="30 300 660 345"          # the KEY row of the PUSH TO TALK card
# ⚠️ The whole window, not just below the field. The menu is positioned so the
# SELECTED row lands on the button, which puts every earlier row ABOVE it - with
# Pause selected, F13 sat at y=177 and a search that started at y=250 declared it
# missing.
MENU="100 60 1250 790"

# ⚠️ AND IT CONFIRMS THE MENU IS ACTUALLY OPEN. The first click on an unfocused
# window only activates it, so one click opens nothing - and searching a menu
# that never opened reports "could not select F13" about a panel that is fine.
open_key_menu() {
    local i
    for i in 1 2 3; do
        bash "$(dirname "$0")/win_click.sh" "click 383,320" >/dev/null 2>&1
        sleep 1.5
        bash "$(dirname "$0")/win_find.sh" "no system-wide key" $MENU >/dev/null && return 0
    done
    return 1
}

# choose <regex matching the menu row> <regex the KEY field must then show>
#
# ⚠️ THE ROW IS FOUND, NOT CALCULATED. Flutter aligns the SELECTED row with the
# button and clamps the menu at the screen edge, so a row's absolute position
# depends on what is already chosen: one run clicked "Pause" while reporting it
# had chosen F13, and the next missed the menu entirely because the previous
# session had left F12 selected. Both were green-ish. Read the screen.
choose() {
    local row="$1" want="$2" try xy
    for try in 1 2 3; do
        open_key_menu || { key "esc" 1; continue; }
        # ⚠️ SCROLL THE MENU TO THE TOP BEFORE LOOKING. The menu is itself a
        # scroll view positioned on the SELECTED row, so with Pause chosen the
        # F13 row was not merely off to one side - it was not rendered at all,
        # and searching for it reported it missing from a chooser that has it.
        # Eight Ups is more than the list is long; the highlight stops at the top.
        local u
        for u in 1 2 3 4 5 6 7 8; do key "up" 0.15; done
        # While the menu is open it covers the KEY field, so a match in this
        # region is a menu row and not the field showing the current value.
        if xy=$(bash "$(dirname "$0")/win_find.sh" "$row" $MENU); then
            bash "$(dirname "$0")/win_click.sh" "click ${xy% *},${xy#* }" >/dev/null 2>&1
            sleep 2
            bash "$(dirname "$0")/win_read.sh" $KEY_FIELD | grep -qE "$want" && return 0
        else
            # Menu did not open, or opened somewhere unexpected. Close it and retry.
            key "esc" 1
        fi
    done
    return 1
}

if choose "F13.*nothing else" "F13"; then
    ok "F13 is the selected key, read back off the screen"
    ALIVE=$($SSH 'powershell -NoProfile -Command "(Get-Process hamdeck_panel -ErrorAction SilentlyContinue | Measure-Object).Count"' 2>/dev/null | tr -dc '0-9')
    [ "${ALIVE:-0}" = "1" ] && ok "the panel survived being given F13" \
        || fail "THE PANEL DIED CHOOSING F13 - the crash is back"
else
    # ⚠️ NOT "the panel survived". If F13 was never selected, the crash was never
    # exercised and saying anything about it would be the false pass this whole
    # file was rewritten to stop.
    fail "could not select F13 in the chooser - the crash test did NOT run"
fi
shot "05-f13-assigned"

echo "== press the key AT THE KEYBOARD, the way a footswitch would"
# ⚠️ AND THE KEY PRESSED IS F12, NOT F13, ON PURPOSE.
#
# `qm monitor sendkey f13` is ACCEPTED and delivers nothing: the monitor prints
# no error, and a probe running inside Windows polling GetAsyncKeyState saw F12
# (VK 0x7B) and never once saw F13 (VK 0x7C). An F13 press test through this
# keyboard can never pass however correct the app is, and it reads as "the PTT is
# broken". Suspect the instrument before the thing under test.
#
# The polling path does not vary by key - same watcher, same table, only the
# virtual-key constant differs - so pressing a key the emulated keyboard CAN
# deliver proves the mechanism. F13 stays the crash test above.
choose "F12.*commonly bound" "F12" && ok "switched to F12, which this keyboard can actually send" \
    || fail "could not select F12 - the press below proves nothing"
BEFORE=$(wc -l < /tmp/windrive-host.log)
key "f12" 2; key "f12" 2; key "f12" 2
sleep 2
shot "06-after-press"
KEYED=$(tail -n +$((BEFORE+1)) /tmp/windrive-host.log | grep -ciE "/api/ptt" || true)
[ "${KEYED:-0}" -ge 1 ] && ok "the key reached the rig ($KEYED ptt calls at the host)" \
    || fail "the key changed nothing at the host - the PTT is not actually armed"
# ⚠️ Only /api/ptt/off is expected here. The down edge deliberately refuses to
# key while the panel is not armed - it says "Not armed. Press E or click ARM
# first." - and the up edge always unkeys defensively. Asserting a ptt/on would
# be asserting a bug.
PRESSES=$(bash "$(dirname "$0")/win_read.sh" 30 380 660 405)
echo "     panel says: $PRESSES"
echo "$PRESSES" | grep -qiE "system-wide" \
    && ok "the panel stopped saying 'claimed' and confirmed the key" \
    || fail "the panel still has not seen a press - it is still only CLAIMING the key"

echo
echo "shots in $OUT - LOOK AT 05 AND 06: the PTT line must go from"
echo "'claimed ... PRESS IT ONCE TO CONFIRM' to a confirmed mode with a press count."
pkill -f "hamdeck-host --users /tmp/windrive" 2>/dev/null
rm -f /tmp/windrive-users.json
[ "$FAILED" -eq 0 ] || exit 1
