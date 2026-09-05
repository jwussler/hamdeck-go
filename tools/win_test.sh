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

VM_HOST="${WIN_TEST_HOST:-192.168.40.168}"
VM_USER="${WIN_TEST_USER:-jwussler}"
EXE="${1:?usage: win_test.sh <installer .exe>}"
# ⚠️ -i, and the shell on the far end is cmd. Setting PowerShell as the SSH
# DefaultShell breaks scp outright - "Connection closed", nothing else - because
# file transfer runs through that shell. Every command below therefore invokes
# powershell explicitly rather than relying on what the login shell happens to be.
KEY="${WIN_TEST_KEY:-$HOME/.ssh/vm_admin}"
SSH="ssh -i $KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 $VM_USER@$VM_HOST"
OUT="${2:-/tmp/win-test}"
mkdir -p "$OUT"
VMID="${WIN_TEST_VMID:-109}"
PVE="${WIN_TEST_PVE:-pve}"
# Leave it as we found it: a test rig that quietly stays powered on is 8 GB of
# somebody else's memory for the rest of the week.
WAS_OFF=0

# ⚠️ THE BOX LIVES POWERED OFF. Joe: "keep the windows desktop but it could be
# powerd down or off and when we start to test stuff we can turn it on." So this
# starts it, waits for SSH to actually answer - not for the VM to report
# "running", which happens a full minute before Windows will talk to anyone -
# and shuts it down again afterwards if it started it.
start_vm() {
    if ssh "$PVE" "qm status $VMID" 2>/dev/null | grep -q running; then
        echo "== the Windows box is already on"
        return 0
    fi
    WAS_OFF=1
    echo "== powering the Windows box on"
    ssh "$PVE" "qm start $VMID" >/dev/null 2>&1
    for i in $(seq 1 60); do
        if timeout 3 bash -c "echo > /dev/tcp/$VM_HOST/22" 2>/dev/null; then
            echo "   ssh answered after $((i * 5))s"
            return 0
        fi
        sleep 5
    done
    echo "   FAIL  it never answered on ssh"
    exit 1
}

stop_vm() {
    [ "$WAS_OFF" -eq 1 ] || { echo "== leaving it on, it was on when we arrived"; return 0; }
    echo "== powering it back off"
    # ⚠️ A CLEAN SHUTDOWN, not qm stop. Pulling the power on Windows leaves it
    # repairing itself on the next boot, which turns a two minute test into ten.
    ssh "$PVE" "qm shutdown $VMID --timeout 120" >/dev/null 2>&1 || \
        ssh "$PVE" "qm stop $VMID" >/dev/null 2>&1
}
trap stop_vm EXIT

start_vm

fail() { echo "  FAIL  $1"; FAILED=1; }
ok()   { echo "  ok    $1"; }
FAILED=0

echo "== copy the installer"
scp -q -i "$KEY" -o StrictHostKeyChecking=accept-new "$EXE" \
    "$VM_USER@$VM_HOST:C:/Users/$VM_USER/Setup.exe" || { fail "copy"; exit 1; }
ok "copied $(basename "$EXE")"

echo "== install it the way an operator would, but silently"
# ⚠️ /VERYSILENT is Inno Setup's own switch. A test that clicks through the
# wizard by hand proves the wizard, not the payload - and cannot run unattended.
$SSH 'powershell -NoProfile -Command "Start-Process -Wait -FilePath C:\Users\'"$VM_USER"'\Setup.exe -ArgumentList \"/VERYSILENT\",\"/SUPPRESSMSGBOXES\",\"/NORESTART\"; exit 0"' \
    && ok "installer returned" || fail "installer did not return cleanly"

echo "== the Microsoft C++ runtime, which a clean Windows does not have"
# ⚠️ THIS CHECK EXISTS BECAUSE THE APP SHIPPED WITHOUT IT. A Flutter Windows app
# needs VCRUNTIME140, VCRUNTIME140_1 and MSVCP140. The developer's machine had
# them from some other program, so it ran there and failed for everybody with a
# clean install - 0xC0000135, and nothing on screen. Either the system has them
# or the package brings them; both are fine, neither is not.
$SSH 'powershell -NoProfile -Command "
  $bad = @()
  foreach ($d in @(\"vcruntime140.dll\",\"vcruntime140_1.dll\",\"msvcp140.dll\")) {
    $sys = Test-Path (Join-Path $env:SystemRoot (Join-Path System32 $d))
    $app = Test-Path (Join-Path \"$env:LOCALAPPDATA\HamDeck Panel\" $d)
    if (-not ($sys -or $app)) { $bad += $d }
  }
  if ($bad.Count) { Write-Output (\"missing: \" + ($bad -join \", \")); exit 1 } else { exit 0 }"' \
    && ok "the C++ runtime is available to the app" \
    || fail "the app cannot start on a clean machine - no Visual C++ runtime"

echo "== is it actually on disk where the operator will look for it"
# ⚠️ THE PATH COMES FROM packaging/hamdeck-panel.iss - {localappdata}\HamDeck
# Panel - not from memory. Guessing it added a "Programs" folder that Inno never
# creates, and the check then failed against a perfectly good install.
$SSH 'powershell -NoProfile -Command "if (Test-Path \"$env:LOCALAPPDATA\HamDeck Panel\hamdeck_panel.exe\") { exit 0 } else { exit 1 }"' \
    && ok "the executable is installed where the .iss puts it" \
    || fail "installed, but the .exe is not at %LOCALAPPDATA%\HamDeck Panel"

echo "== start it IN THE OPERATOR'S SESSION, and see whether it is alive 30 s later"
# ⚠️ SESSION 0 IS NOT A DESKTOP. Start-Process over SSH runs the app in the
# service session, where it has no visible window: the process check passes, the
# screenshot shows an empty desktop, and the app is "running" in a place no
# operator will ever see. A scheduled task marked /it runs it in the logged-on
# session, which is what double-clicking the shortcut does.
$SSH 'powershell -NoProfile -Command "Get-Process hamdeck_panel -ErrorAction SilentlyContinue | Stop-Process -Force"' >/dev/null 2>&1
# ⚠️ REGISTERED WITH PowerShell, NOT schtasks. The schtasks command line needs
# quotes inside quotes inside an ssh argument, and it silently registered a task
# with an EMPTY Execute - which then failed with 0xC0000135 and looked like a
# missing DLL in the app rather than a mangled command line.
$SSH 'powershell -NoProfile -Command "
  $dir = \"$env:LOCALAPPDATA\HamDeck Panel\"
  $act = New-ScheduledTaskAction -Execute (Join-Path $dir hamdeck_panel.exe) -WorkingDirectory $dir
  $pri = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
  Register-ScheduledTask -TaskName hamdecktest -Action $act -Principal $pri -Force | Out-Null
  Start-ScheduledTask -TaskName hamdecktest"' >/dev/null 2>&1
$SSH 'powershell -NoProfile -Command "Start-Sleep -Seconds 30; if (Get-Process hamdeck_panel -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"' \
    && ok "still running after 30 s" || fail "the app died after starting"

echo "== photograph the desktop, because 'running' is not 'drawing'"
# ⚠️ THE PICTURE COMES FROM THE HYPERVISOR, NOT FROM INSIDE WINDOWS. An SSH
# session has no interactive desktop - CopyFromScreen there captures nothing,
# and the failure reads as "the app drew nothing" when the app is fine. The
# QEMU console sees the actual framebuffer and needs no cooperation from the
# guest at all.
VMID="${WIN_TEST_VMID:-109}"
PVE="${WIN_TEST_PVE:-pve}"
ssh "$PVE" "echo 'screendump /tmp/hamdeck-shot.ppm' | qm monitor $VMID" >/dev/null 2>&1
sleep 2
ssh "$PVE" "cat /tmp/hamdeck-shot.ppm" > "$OUT/hamdeck-shot.ppm" 2>/dev/null
if [ -s "$OUT/hamdeck-shot.ppm" ]; then
    python3 -c "from PIL import Image; Image.open('$OUT/hamdeck-shot.ppm').save('$OUT/hamdeck-shot.png')" 2>/dev/null \
        && ok "screenshot at $OUT/hamdeck-shot.png" || ok "console frame at $OUT/hamdeck-shot.ppm"
else
    fail "could not photograph the console"
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "WINDOWS: the installer runs, the app starts and stays up. LOOK AT THE SHOT."
    exit 0
fi
echo "WINDOWS BUILD IS NOT SHIPPABLE - see the failures above."
exit 1
