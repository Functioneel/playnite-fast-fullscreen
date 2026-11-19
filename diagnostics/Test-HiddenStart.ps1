# Test-HiddenStart.ps1
# Two questions:
#   A) Does a hidden launch (STARTUPINFO SW_HIDE) keep the fullscreen window invisible?
#   B) If launched normally, how long does the HWND exist before it becomes visible?
#      (If it exists invisible for a while, the helper can hide it pre-show.)
param([switch]$KeepRunning)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class HS {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }

    public static IntPtr AnyWindow(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && GetWindow(h, 4) == IntPtr.Zero) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct WINDOWPLACEMENT {
        public int length; public int flags; public int showCmd;
        public POINT ptMinPosition; public POINT ptMaxPosition;
        public RECT rcNormalPosition;
    }

    // The real fullscreen window: largest unparented top-level window, ignoring the
    // small hidden WPF/CEF helper windows.
    public static IntPtr FindMain(uint pid) {
        IntPtr best = IntPtr.Zero; long bestArea = 0;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && GetWindow(h, 4) == IntPtr.Zero) {
                var wp = new WINDOWPLACEMENT();
                wp.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
                if (GetWindowPlacement(h, ref wp)) {
                    int w = wp.rcNormalPosition.R - wp.rcNormalPosition.L;
                    int ht = wp.rcNormalPosition.B - wp.rcNormalPosition.T;
                    long area = (long)w * ht;
                    if (w >= 1200 && ht >= 700 && area > bestArea) { bestArea = area; best = h; }
                }
            }
            return true;
        }, IntPtr.Zero);
        return best;
    }
}
"@

if (Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue) {
    Write-Error 'Playnite is already running. Close it first.'
    return
}

$log = Join-Path $env:APPDATA 'Playnite\playnite.log'
$exe = Join-Path $env:LOCALAPPDATA 'Playnite\Playnite.FullscreenApp.exe'

function Run([string]$mode) {
    Write-Host ''
    Write-Host "=== $mode launch ==="
    $before = (Get-Content $log).Count
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($mode -eq 'hidden') {
        $p = Start-Process -FilePath $exe -ArgumentList '--hidesplashscreen' -PassThru -WindowStyle Hidden
    } else {
        $p = Start-Process -FilePath $exe -ArgumentList '--hidesplashscreen' -PassThru
    }

    $firstHwnd = [IntPtr]::Zero; $tHwnd = $null; $tVisible = $null; $visibleAtFirstSight = $null
    while ($sw.Elapsed.TotalSeconds -lt 40) {
        $h = [HS]::FindMain([uint32]$p.Id)
        if ($h -ne [IntPtr]::Zero) {
            if ($firstHwnd -eq [IntPtr]::Zero) {
                $firstHwnd = $h
                $tHwnd = $sw.Elapsed.TotalMilliseconds
                $visibleAtFirstSight = [HS]::IsWindowVisible($h)
            }
            if ([HS]::IsWindowVisible($h)) { $tVisible = $sw.Elapsed.TotalMilliseconds; break }
        }
        Start-Sleep -Milliseconds 10
    }

    # wait for render regardless
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        if ((Get-Content $log | Select-Object -Skip $before) -match 'Render screen') { break }
    }
    Start-Sleep -Seconds 3

    $all = Get-Process -Name 'Playnite*'
    $visibleWindows = @()
    foreach ($proc in $all) {
        $h = [HS]::FindMain([uint32]$proc.Id)
        if ($h -ne [IntPtr]::Zero) { $visibleWindows += [PSCustomObject]@{ Pid = $proc.Id; H = $h; Visible = [HS]::IsWindowVisible($h) } }
    }

    "first main HWND at      : $(if ($tHwnd) { [math]::Round($tHwnd) } else { '-' }) ms  (visible at first sight: $visibleAtFirstSight)"
    "first became visible at : $(if ($tVisible) { [math]::Round($tVisible) } else { 'never' }) ms"
    "invisible head start    : $(if ($tHwnd -and $tVisible) { [math]::Round($tVisible - $tHwnd) } else { '-' }) ms"
    "WS total                : $([math]::Round((($all | Measure-Object WorkingSet64 -Sum).Sum)/1MB)) MB"
    $visibleWindows | ForEach-Object { "  pid $($_.Pid) hwnd $($_.H) visible=$($_.Visible)" }

    # if it launched hidden, bring it up once to prove it still works
    if ($mode -eq 'hidden') {
        $target = ($visibleWindows | Select-Object -First 1)
        if ($target) {
            [void][HS]::ShowWindow($target.H, 9); [void][HS]::SetForegroundWindow($target.H)
            Start-Sleep -Seconds 2
            "after ShowWindow: visible=$([HS]::IsWindowVisible($target.H)) iconic=$([HS]::IsIconic($target.H))"
        }
    }

    $p.Refresh()
    if (-not $p.HasExited) { $p.CloseMainWindow() | Out-Null }
    Start-Sleep -Seconds 4
    Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force }
    Start-Sleep -Seconds 2
}

Run 'normal'
Run 'hidden'
'cleaned up'
