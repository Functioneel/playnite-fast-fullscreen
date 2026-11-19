# Observe-WindowVisibility.ps1
# Independent observer: polls Playnite's main window every few ms and records every
# visibility transition with a timestamp. Used to measure how long a hidden-at-boot
# window is actually visible. Runs in its own process so nothing pumps messages for it.
param([int]$Seconds = 30, [string]$OutFile = (Join-Path $env:TEMP 'playnite-visibility.log'))

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Vis {
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

$sw = [System.Diagnostics.Stopwatch]::StartNew()
"0 start" | Set-Content -Path $OutFile
$last = $null

while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    $p = Get-Process -Name 'Playnite.FullscreenApp' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) {
        $h = [Vis]::Find([uint32]$p.Id)
        if ($h -ne [IntPtr]::Zero) {
            $v = [Vis]::IsWindowVisible($h)
            if ($v -ne $last) {
                "$([math]::Round($sw.Elapsed.TotalMilliseconds)) visible=$v" | Add-Content -Path $OutFile
                $last = $v
            }
        }
    }
}
"$([math]::Round($sw.Elapsed.TotalMilliseconds)) end" | Add-Content -Path $OutFile
