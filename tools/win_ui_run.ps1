# Run win_ui.ps1 in the operator's interactive session and wait for it.
# Registration is verified, because a Start-ScheduledTask on a task that does not
# exist returns nothing and looks exactly like success.
$name = 'hamdeckui'
$act = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\win_ui.ps1'
$pri = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
Register-ScheduledTask -TaskName $name -Action $act -Principal $pri -Force | Out-Null
if (-not (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) {
    Write-Output "REGISTER FAILED"; exit 2
}
$res = Join-Path $env:USERPROFILE "hamdeck-ui-result.txt"
Remove-Item $res -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName $name
foreach ($i in 1..40) {
    Start-Sleep -Milliseconds 500
    if ((Test-Path $res) -and ((Get-Content $res) -contains 'done')) { break }
}
if (Test-Path $res) { Get-Content $res } else { Write-Output "NO RESULT" }
