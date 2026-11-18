# Test-MinimizeRestore.ps1
# Verifies option C's premise: if Playnite fullscreen is minimized instead of quit,
# does starting the exe again restore it instantly (instead of cold starting)?

if (Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue) {
    Write-Error 'Playnite is already running. Close it first - this script starts and stops its own instance.'
    return
}

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
}
"@

$log = Join-Path $env:APPDATA 'Playnite\playnite.log'
$exe = Join-Path $env:LOCALAPPDATA 'Playnite\Playnite.FullscreenApp.exe'

$before = (Get-Content $log).Count
$p = Start-Process -FilePath $exe -ArgumentList '--hidesplashscreen' -PassThru
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
    if ((Get-Content $log | Select-Object -Skip $before) -match 'Render screen') { break }
}
Start-Sleep -Seconds 2

$p.Refresh()
$hwnd = $p.MainWindowHandle
"initial handle: $hwnd  iconic: $([Win32]::IsIconic($hwnd))"

[Win32]::ShowWindow($hwnd, 6) | Out-Null   # SW_MINIMIZE
Start-Sleep -Seconds 2
$p.Refresh()
"after minimize - iconic: $([Win32]::IsIconic($p.MainWindowHandle))  pid: $($p.Id)"

# Simulate the user hitting the boot shortcut again
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$p2 = Start-Process -FilePath $exe -ArgumentList '--hidesplashscreen' -PassThru
$t2 = $p2.StartTime
Start-Sleep -Seconds 4
$p2.Refresh()
$p.Refresh()
"second process exited: $($p2.HasExited)  elapsed: $([math]::Round($sw.Elapsed.TotalSeconds,2))s"
"first instance still alive: $(-not $p.HasExited)"
"first instance iconic now: $([Win32]::IsIconic($p.MainWindowHandle))  visible: $([Win32]::IsWindowVisible($p.MainWindowHandle))"

"---- log lines produced by second launch ----"
$new = Get-Content $log | Select-Object -Skip $before
$idx = ($new | Select-String -Pattern 'App arguments' | Select-Object -Last 1).LineNumber
if ($idx) { $new[($idx-1)..([math]::Min($idx+12, $new.Count-1))] } else { $new | Select-Object -Last 6 }

Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue | Select-Object Name, Id | Format-Table -AutoSize
Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() | Out-Null }
Start-Sleep -Seconds 4
Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force }
