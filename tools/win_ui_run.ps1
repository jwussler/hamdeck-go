# Run win_ui.ps1 in the operator's interactive session and wait for it.
# Registration is verified: Start-ScheduledTask on a task that does not exist
# returns nothing and looks exactly like success.
param([string]$Nonce = '', [string]$Actions = '')
$name = 'hamdeckui'
$arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\win_ui.ps1 ' +
       "-Nonce `"$Nonce`" -Actions `"$Actions`""
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
$pri = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
Register-ScheduledTask -TaskName $name -Action $act -Principal $pri -Force | Out-Null
if (-not (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) {
    Write-Output "REGISTER FAILED"; exit 2
}
$res = Join-Path $env:USERPROFILE "hamdeck-ui-result.txt"
Remove-Item $res -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName $name
foreach ($i in 1..60) {
    Start-Sleep -Milliseconds 500
    if ((Test-Path $res) -and ((Get-Content $res) -contains 'done')) { break }
}
if (Test-Path $res) { Get-Content $res } else { Write-Output "NO RESULT" }
