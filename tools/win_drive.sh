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

# ⚠️ ONE AT A TIME. Two of these ran against the same VM at once - a chained
# starter fired after one had already been launched by hand - and they fought
# each other over the mouse and keyboard while interleaving into the same log.
# Clicks from one landed during the other's typing, which looks exactly like the
# flaky UI this script exists to rule out.
LOCK=/tmp/hamdeck-win-drive.lock
exec 9>"$LOCK"
if ! flock -n 9; then
    echo "another win_drive.sh is already driving this VM - refusing to fight it for the mouse"
    exit 1
fi
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
#
# ⚠️ AND EVERY FIELD IS READ BACK. Tuning sleeps did not make this reliable: one
# run put the address in USERNAME and the username in PASSWORD, the next lost the
# address entirely and shifted everything the other way, and a third dropped the
# first three characters of the password so "windrive" arrived as "drive". Each
# time the run carried on and failed something unrelated several steps later.
# Type it, look at it, retype it if it is wrong.
STATION_Y=314
USER_Y=392
PASS_Y=470

click_at() { # click_at <y>  - twice, because the first click only activates
    bash "$(dirname "$0")/win_click.sh" "click 650,$1" >/dev/null 2>&1
    sleep 0.8
    bash "$(dirname "$0")/win_click.sh" "click 650,$1" >/dev/null 2>&1
    sleep 0.8
}

fill() { # fill <y> <text> <regex it must then read, or "-" to count ink>
    local y="$1" text="$2" want="$3" try got ink
    for try in 1 2 3; do
        click_at "$y"
        key "ctrl-a" 0.4; key "delete" 0.6
        bash "$(dirname "$0")/win_sendtext.sh" "$VMID" "$text"
        sleep 1
        if [ "$want" = "-" ]; then
            # ⚠️ A PASSWORD IS DOTS, SO COUNT THE INK. An empty box looks exactly
            # like a full one to OCR, and a box that silently never got typed into
            # read as success while the run blamed the panel for "still being on
            # the login screen". Measured on this panel: empty ~22 pixels of ink,
            # eight characters ~377. (An earlier note said 763 - that was
            # SIXTEEN characters, because the box had not been cleared first.
            # Baseline against a known state or the number means nothing.)
            ink=$(bash "$(dirname "$0")/win_ink.sh" 480 $((y - 12)) 820 $((y + 12)))
            [ "${ink:-0}" -gt 120 ] && return 0
            continue
        fi
        got=$(bash "$(dirname "$0")/win_read.sh" 460 $((y - 26)) 850 $((y + 22)))
        case "$got" in
            *$want*) return 0 ;;
        esac
    done
    return 1
}

fill "$STATION_Y" "http://$SHACK:$PORT" "$SHACK" \
    && ok "the station address went into the STATION box" \
    || fail "could not type the station address - nothing below this can pass"
fill "$USER_Y" "drive" "drive" \
    && ok "the username went into the USERNAME box" \
    || fail "could not type the username"
# ⚠️ NOT A VERDICT - A RETRY TRIGGER. This drives fill() to type again when the
# box looks empty, but it does NOT fail the run: a pass where the ink read low
# and the login then worked perfectly proved the measurement is less reliable
# than the thing it was standing in for. The gate is whether the panel connects,
# checked next, and that one is unambiguous.
if fill "$PASS_Y" "windrive" "-"; then
    ok "the password box has something in it"
else
    echo "     note: the password box still looks empty after 3 tries - if the"
    echo "     connection check below passes, this measurement is what is wrong"
fi
shot "02-login-typed"
key "ret" 10
shot "03-operate"

echo "== is the panel actually talking to the rig?"
# ⚠️ COUNTING LOGIN REQUESTS IS NOT CHECKING THAT ONE WORKED. The host logs
# "POST /api/auth/login" for a REFUSED password too, so a run where three
# characters of the password went missing reported "the host saw a login" and
# then spent six minutes hunting a PTT chooser on a login form. Ask the panel
# what it is showing instead: SIGNAL only exists once connected.
SESSIONS=$(grep -c "POST /api/auth/login" /tmp/windrive-host.log 2>/dev/null | head -1 | tr -dc '0-9')
SESSIONS=${SESSIONS:-0}
if bash "$(dirname "$0")/win_find.sh" "SIGNAL" 0 170 900 260 >/dev/null; then
    ok "the panel is connected and drawing the rig (after $SESSIONS login attempts)"
else
    fail "the panel is still on the login screen - see 03-operate.png"
    echo "     the host saw $SESSIONS login attempt(s), which is not the same as one working"
fi

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
# choose <regex matching the menu row> <regex the KEY field must then show>
#
# ⚠️ THE ROW IS FOUND, NOT CALCULATED. Flutter aligns the SELECTED row with the
# button and clamps the menu at the screen edge, so a row's absolute position
# depends on what is already chosen: one run clicked "Pause" while reporting it
# had chosen F13, and the next missed the menu entirely.
#
# ⚠️ AND THERE IS NO SEPARATE "IS THE MENU OPEN?" CHECK ANY MORE. There was one,
# and it looked for the "Off - no system-wide key" row - which is the FIRST row,
# and Flutter scrolls it out of view whenever a key further down is selected. So
# with Pause chosen the check said "not open" about a menu that was open, clicked
# again, and that second click CLOSED it. The loop oscillated and three tries
# failed as reliably as one. Finding the target row is itself proof the menu is
# open; nothing else needs asking.
choose() {
    local row="$1" want="$2" try xy
    for try in 1 2 3; do
        key "esc" 0.6                       # a retry starts from closed, always
        bash "$(dirname "$0")/win_click.sh" "click 383,320" >/dev/null 2>&1
        sleep 1.5
        # ⚠️ Scroll the menu to the top before looking: it is itself a scroll
        # view positioned on the selected row, so with Pause chosen the F13 row
        # was not off to one side, it was not rendered at all. One connection for
        # all eight - a round trip per keystroke made this take minutes.
        ssh "$PVE" "qm monitor $VMID" >/dev/null 2>&1 <<'UPS'
sendkey up
sendkey up
sendkey up
sendkey up
sendkey up
sendkey up
sendkey up
sendkey up
UPS
        sleep 1
        if xy=$(WIN_FIND_LAST="${WIN_FIND_LAST:-}" bash "$(dirname "$0")/win_find.sh" "$row" $MENU); then
            bash "$(dirname "$0")/win_click.sh" "click ${xy% *},${xy#* }" >/dev/null 2>&1
            sleep 2
            bash "$(dirname "$0")/win_read.sh" $KEY_FIELD | grep -qE "$want" && return 0
        fi
    done
    return 1
}

if choose "footswitch" "F13"; then
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
WIN_FIND_LAST=1 choose "commonly bound" "F12" && ok "switched to F12, which this keyboard can actually send" \
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
echo "== and it must work with the panel in the BACKGROUND"
# ⚠️ THIS IS THE WHOLE POINT OF A SYSTEM-WIDE KEY, and until now it was only
# reasoned about. GetAsyncKeyState is documented as global, but "documented as"
# is not "measured on this build". The operator is looking at a logger or a
# cluster, not at us - a PTT that only works while the panel has focus is not
# the feature that was asked for.
#
# Focus something else that is definitely not the panel, then press the key.
bash "$(dirname "$0")/win_click.sh" "click 640,770" >/dev/null 2>&1   # the taskbar
sleep 2
BG_BEFORE=$(wc -l < /tmp/windrive-host.log)
key "f12" 2; key "f12" 2
sleep 2
shot "07-background-press"
BG=$(tail -n +$((BG_BEFORE+1)) /tmp/windrive-host.log | grep -ciE "/api/ptt" || true)
[ "${BG:-0}" -ge 1 ] \
    && ok "the key still reached the rig with the panel in the background ($BG ptt calls)" \
    || fail "the key only works when the panel has focus - that is not a system-wide PTT"

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
