#!/usr/bin/env bash
# Click at real screen coordinates inside the Windows VM's logged-on session.
#
#   win_click.sh "click 650,314" "sleep 500" "click 300,480"
#
# ⚠️ THE ACTIONS TRAVEL AS A TASK ARGUMENT, WITH A NONCE, AND THE NONCE IS
# CHECKED. They used to be written to a file on the VM, and the write silently
# did not happen: the previous call's file stayed on disk, the scheduled task
# read that, and a click aimed at the password box landed on a dropdown from
# minutes earlier - while reporting "done". Text went into the wrong field, a
# field was left empty, a menu row was never selected, and every one of those
# looked like a bug in the app. A write that succeeds and changes nothing is the
# invocation, not the API.
set -euo pipefail
VM_HOST="${WIN_TEST_HOST:-192.168.40.168}"
VM_USER="${WIN_TEST_USER:-jwussler}"
KEY="${WIN_TEST_KEY:-$HOME/.ssh/vm_admin}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$VM_USER@$VM_HOST")
HERE="$(cd "$(dirname "$0")" && pwd)"

# The two PowerShell files go up every time. They are small, and a run that
# assumes they are already there is how win_test.sh once "passed" against a
# scheduled task somebody had registered by hand hours earlier.
scp -q -i "$KEY" "$HERE/win_ui.ps1" "$HERE/win_ui_run.ps1" "$VM_USER@$VM_HOST:C:/"

NONCE="$(date +%s)$RANDOM"
# ⚠️ No spaces and no shell metacharacters on the wire - see win_ui.ps1.
ACTIONS=""
for a in "$@"; do
    ACTIONS="${ACTIONS}${ACTIONS:++}$(printf '%s' "$a" | tr ' ' ':')"
done

OUT=$("${SSH[@]}" "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\win_ui_run.ps1 -Nonce $NONCE -Actions $ACTIONS" 2>&1 | tr -d '\r')

# ⚠️ The result must carry THIS call's nonce. Without it a stale result file is
# indistinguishable from a successful click.
if ! grep -q "^nonce $NONCE$" <<<"$OUT"; then
    echo "STALE OR MISSING RESULT - this is not the result of this call" >&2
    echo "$OUT" >&2
    exit 1
fi
grep -v "^nonce " <<<"$OUT"
