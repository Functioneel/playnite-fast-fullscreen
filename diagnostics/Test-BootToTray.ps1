# Test-BootToTray.ps1
# Simulates login: restarts the helper, launches Playnite exactly like the Startup
# shortcut does, and checks that the window is never visibly shown and ends up in
# the tray. An independent observer process records visibility transitions.
param([int]$ObserveSeconds = 30)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class BTT {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WP p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct WP {
        public int length; public int flags; public int showCmd;
        public POINT ptMin; public POINT ptMax; public RECT rcNormal;
    }
    public static IntPtr Find(uint pid) {
        IntPtr best = IntPtr.Zero; long bestArea = 0;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && GetWindow(h, 4) == IntPtr.Zero) {
                var wp = new WP(); wp.length = Marshal.SizeOf(typeof(WP));
                if (GetWindowPlacement(h, ref wp)) {
                    int w = wp.rcNormal.R - wp.rcNormal.L, ht = wp.rcNormal.B - wp.rcNormal.T;
                    long a = (long)w * ht;
                    if (w >= 1200 && ht >= 700 && a > bestArea) { bestArea = a; best = h; }
                }
            }
            return true;
        }, IntPtr.Zero);
        return best;
    }
}
"@

if (Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue) {
    Write-Error 'Playnite is already running. Close it first - this test starts and stops its own instance.'
    return
}

$dir = Split-Path $PSCommandPath
$repo = Split-Path $dir
$vbs = Join-Path $repo 'scripts\PlayniteTray.vbs'
$trayLog = Join-Path $env:TEMP 'playnite-tray.log'
$obsLog = Join-Path $env:TEMP 'playnite-visibility.log'
$desktop = Join-Path $env:LOCALAPPDATA 'Playnite\Playnite.DesktopApp.exe'

# fresh helper, as at login
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*-File*PlayniteTray.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -Filter "Name = 'wscript.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*PlayniteTray.vbs*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
Remove-Item $trayLog, $obsLog -Force -ErrorAction SilentlyContinue

Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + $vbs + '"')
Start-Sleep -Seconds 2

$obs = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', ('"' + (Join-Path $dir 'Observe-WindowVisibility.ps1') + '"'),
    '-Seconds', "$ObserveSeconds", '-OutFile', ('"' + $obsLog + '"')
)
Start-Sleep -Seconds 1

"launching like the Startup shortcut does (desktop stub)..."
Start-Process -FilePath $desktop -ArgumentList '--hidesplashscreen' | Out-Null

Start-Sleep -Seconds ($ObserveSeconds + 4)

"---- visibility transitions (observer) ----"
if (Test-Path $obsLog) { Get-Content $obsLog } else { 'no observer log' }

"---- state now ----"
$p = Get-Process -Name 'Playnite.FullscreenApp' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($p) {
    $h = [BTT]::Find([uint32]$p.Id)
    "pid $($p.Id)  visible=$([BTT]::IsWindowVisible($h))  WS=$([math]::Round((($p | Measure-Object WorkingSet64).Sum)/1MB)) MB"
    $all = Get-Process -Name 'Playnite*'
    "all Playnite WS = $([math]::Round((($all | Measure-Object WorkingSet64 -Sum).Sum)/1MB)) MB"
} else { 'Playnite not running' }

"---- helper log ----"
Get-Content $trayLog -ErrorAction SilentlyContinue

"---- user opens the Playnite shortcut while it is hidden ----"
$exe = Join-Path $env:LOCALAPPDATA 'Playnite\Playnite.FullscreenApp.exe'
Start-Process -FilePath $exe -ArgumentList '--hidesplashscreen' | Out-Null
Start-Sleep -Seconds 5
$p = Get-Process -Name 'Playnite.FullscreenApp' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($p) {
    $h = [BTT]::Find([uint32]$p.Id)
    "after shortcut: visible=$([BTT]::IsWindowVisible($h))  (expect True)"
}
Start-Sleep -Seconds 3
"---- helper log after restore ----"
Get-Content $trayLog -ErrorAction SilentlyContinue | Select-Object -Last 6

Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() | Out-Null }
Start-Sleep -Seconds 4
Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force }
'cleaned up'
