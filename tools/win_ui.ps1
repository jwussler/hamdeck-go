# Click inside the logged-on Windows session, at real screen pixels.
#
# ⚠️ THE HYPERVISOR MOUSE CANNOT DO THIS. `qm monitor mouse_move` always emits
# RELATIVE deltas, even though VM 109's active pointer is an absolute HID tablet
# - the tablet accumulates them in an UNBOUNDED counter, so one large negative
# move (an attempt to home the pointer at 0,0) pushed it past -40000 and no
# positive move could ever bring it back on screen. Every "click the STATION
# field" after that landed nowhere, and the keystrokes that followed went to
# whatever else had focus - an evening of logins that silently never happened.
# Do not reintroduce mouse_move for pointing.
#
# ⚠️ AND IT MUST RUN IN THE OPERATOR'S SESSION. SetCursorPos from an ssh shell
# does nothing at all: session 0 has no desktop. This is started the same way the
# panel is, by a scheduled task with an Interactive principal - see win_ui_run.ps1.
#
# Reads one action per line from $env:USERPROFILE\hamdeck-ui-actions.txt, appends to $env:USERPROFILE\hamdeck-ui-result.txt:
#   click <x>,<y>
#   sleep <ms>
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
Remove-Item $res -ErrorAction SilentlyContinue
foreach ($line in (Get-Content (Join-Path $env:USERPROFILE "hamdeck-ui-actions.txt"))) {
    $line = $line.Trim()
    if (-not $line) { continue }
    $verb, $arg = $line -split '\s+', 2
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
