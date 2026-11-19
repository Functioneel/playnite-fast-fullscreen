# Test-FocusFromHidden.ps1
# If Playnite is hidden with SW_HIDE (not minimized), does launching the exe again
# (the "Focus" pipe command) bring the window back, or does it stay invisible?
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class FH {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WP p);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
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

$log = Join-Path $env:APPDATA 'Playnite\playnite.log'
$exe = Join-Path $env:LOCALAPPDATA 'Playnite\Playnite.FullscreenApp.exe'

$before = (Get-Content $log).Count
$p = Start-Process -FilePath $exe -ArgumentList '--hidesplashscreen' -PassThru
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
    if ((Get-Content $log | Select-Object -Skip $before) -match 'Render screen') { break }
}
Start-Sleep -Seconds 4
$h = [FH]::Find([uint32]$p.Id)
"started: visible=$([FH]::IsWindowVisible($h)) iconic=$([FH]::IsIconic($h))"

[void][FH]::ShowWindow($h, 0)   # SW_HIDE
Start-Sleep -Seconds 2
"hidden : visible=$([FH]::IsWindowVisible($h)) iconic=$([FH]::IsIconic($h))"

# user launches the Playnite shortcut again
$before2 = (Get-Content $log).Count
$p2 = Start-Process -FilePath $exe -ArgumentList '--hidesplashscreen' -PassThru
Start-Sleep -Seconds 5
"second instance exited: $($p2.HasExited)"
"after Focus: visible=$([FH]::IsWindowVisible($h)) iconic=$([FH]::IsIconic($h))"
"---- log lines from second launch ----"
Get-Content $log | Select-Object -Skip $before2 | Select-Object -First 5

Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() | Out-Null }
Start-Sleep -Seconds 4
Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force }
'cleaned up'
