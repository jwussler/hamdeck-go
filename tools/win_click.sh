#!/usr/bin/env bash
# Click at real screen coordinates inside VM 109's logged-on Windows session.
#   winclick.sh "click 650,314" "sleep 500" "click 300,480"
set -euo pipefail
VM_HOST="${WIN_TEST_HOST:-192.168.40.168}"
VM_USER="${WIN_TEST_USER:-jwussler}"
KEY="${WIN_TEST_KEY:-$HOME/.ssh/vm_admin}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$VM_USER@$VM_HOST")
# ⚠️ The actions travel as a FILE. Quoting a list through ssh, cmd, PowerShell
# and a scheduled-task argument string is four chances to silently truncate it.
# ⚠️ The two PowerShell files go up every time. They are small, and a run that
# assumes they are already there is exactly how win_test.sh spent an evening
# "passing" against a scheduled task somebody had registered by hand.
HERE="$(cd "$(dirname "$0")" && pwd)"
scp -q -i "$KEY" "$HERE/win_ui.ps1" "$HERE/win_ui_run.ps1" "$VM_USER@$VM_HOST:C:/"

printf '%s\n' "$@" | "${SSH[@]}" 'powershell -NoProfile -Command "$input | Set-Content $env:USERPROFILE\hamdeck-ui-actions.txt"'
"${SSH[@]}" 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\win_ui_run.ps1' 2>&1 | tr -d '\r'
