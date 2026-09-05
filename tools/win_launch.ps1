# Launch the installed panel in the logged-on session, and say what happened.
#
# ⚠️ A SCRIPT FILE, NOT A COMMAND LINE THROUGH SSH. Registering this task with an
# inline PowerShell string failed SILENTLY - Register-ScheduledTask never ran,
# Start-ScheduledTask on a missing task returns nothing, and the test reported
# "the panel is not running" about an app that was never asked to start. The one
# run that appeared to work was starting a task registered by hand hours earlier.
#
# ⚠️ AND IT VERIFIES. Every step here is checked and printed, because the failure
# mode above is invisible by construction.
param([string]$TaskName = 'hamdeckpanel')

$dir = Join-Path $env:LOCALAPPDATA 'HamDeck Panel'
$exe = Join-Path $dir 'hamdeck_panel.exe'
if (-not (Test-Path $exe)) { Write-Output "MISSING: $exe"; exit 1 }

Get-Process hamdeck_panel -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

$act = New-ScheduledTaskAction -Execute $exe -WorkingDirectory $dir
# ⚠️ Interactive: session 0 has no desktop, so a windowed app started there runs
# where no operator can ever see it.
$pri = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
Register-ScheduledTask -TaskName $TaskName -Action $act -Principal $pri -Force | Out-Null

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) { Write-Output "REGISTER FAILED: $TaskName"; exit 2 }
Write-Output "registered $TaskName -> $($task.Actions.Execute)"

Start-ScheduledTask -TaskName $TaskName
foreach ($i in 1..24) {
    Start-Sleep -Seconds 5
    if (Get-Process hamdeck_panel -ErrorAction SilentlyContinue) {
        Write-Output "running after $($i * 5)s"
        exit 0
    }
}
Write-Output "NEVER STARTED (last task result: $((Get-ScheduledTaskInfo -TaskName $TaskName).LastTaskResult))"
exit 3
