# Test-ManualLaunch.ps1
# Guards the boot watcher against overreach: if you launch Playnite yourself well after
# login, the helper must NOT hide it. The watcher only covers a Playnite that starts
# within 45 s of the helper (i.e. the boot path).
param([int]$DelaySeconds = 50)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ML {
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

if (Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue) { Write-Error 'Close Playnite first.'; return }

$dir = Split-Path $PSCommandPath
$repo = Split-Path $dir
$vbs = Join-Path $repo 'scripts\PlayniteTray.vbs'
$trayLog = Join-Path $env:TEMP 'playnite-tray.log'
$exe = Join-Path $env:LOCALAPPDATA 'Playnite\Playnite.FullscreenApp.exe'

Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*-File*PlayniteTray.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -Filter "Name = 'wscript.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*PlayniteTray.vbs*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
Remove-Item $trayLog -Force -ErrorAction SilentlyContinue

Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + $vbs + '"')
"helper started; waiting $DelaySeconds s before launching Playnite like a user would..."
Start-Sleep -Seconds $DelaySeconds

$p = Start-Process -FilePath $exe -ArgumentList '--hidesplashscreen' -PassThru
Start-Sleep -Seconds 14

$hwnd = [ML]::Find([uint32]$p.Id)
"after manual launch: visible=$([ML]::IsWindowVisible($hwnd))  (expect True - it must stay up)"
"---- helper log ----"
Get-Content $trayLog -ErrorAction SilentlyContinue

Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() | Out-Null }
Start-Sleep -Seconds 4
Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force }
'cleaned up'
