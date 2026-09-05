# Click inside the logged-on Windows session, at real screen pixels.
#
# ⚠️ THE HYPERVISOR MOUSE CANNOT DO THIS. `qm monitor mouse_move` always emits
# RELATIVE deltas, even though this guest's active pointer is an absolute HID
# tablet, and the tablet accumulates them in an UNBOUNDED counter - one large
# negative move to "home" the pointer pushed it past -40000 where no positive
# move could bring it back. Every click then landed nowhere and the keystrokes
# after it went to whatever else had focus. Do not reintroduce mouse_move.
#
# ⚠️ AND IT MUST RUN IN THE OPERATOR'S SESSION. SetCursorPos from an ssh shell
# does nothing: session 0 has no desktop. Started by win_ui_run.ps1 as a
# scheduled task with an Interactive principal.
#
# ⚠️ THE ACTIONS ARRIVE AS AN ARGUMENT AND CARRY A NONCE. They used to be written
# to a file, and the write silently did not happen: the previous run's file
# stayed on disk, the task read it, and a click aimed at the password box landed
# on a dropdown from minutes earlier while reporting success. The nonce is
# echoed back so the caller can prove the result belongs to THIS call.
#
#   win_ui.ps1 -Nonce <id> -Actions click:650,470+click:300,480
param([string]$Nonce = '', [string]$Actions = '')

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Drawing;
public class Ptr {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point p);
}
"@ -ReferencedAssemblies System.Drawing

$res = Join-Path $env:USERPROFILE "hamdeck-ui-result.txt"
Set-Content -Path $res -Value "nonce $Nonce"

foreach ($line in ($Actions -split '\+')) {
    $line = $line.Trim()
    if (-not $line) { continue }
    $verb, $arg = $line -split ':', 2
    switch ($verb) {
        'click' {
            $xy = $arg -split ','
            [void][Ptr]::SetCursorPos([int]$xy[0], [int]$xy[1])
            Start-Sleep -Milliseconds 250
            [Ptr]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)   # left button down
            Start-Sleep -Milliseconds 60
            [Ptr]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)   # left button up
            # ⚠️ Read the pointer BACK. A SetCursorPos that silently did nothing
            # is the whole failure this file exists to end.
            $p = New-Object System.Drawing.Point
            [void][Ptr]::GetCursorPos([ref]$p)
            Add-Content $res "clicked $($p.X),$($p.Y)"
        }
        'sleep' { Start-Sleep -Milliseconds ([int]$arg) }
        default { Add-Content $res "unknown action: $line" }
    }
    Start-Sleep -Milliseconds 300
}
Add-Content $res "done"
