# Measure-Memory.ps1
# Measures Playnite's footprint and tests working-set trimming:
#   1. baseline while visible
#   2. after hide (tray helper)
#   3. after EmptyWorkingSet + low memory priority
#   4. restore: how long, and does the theme still render (PrintWindow, so Rainmeter
#      overlay can't interfere)?
param([switch]$KeepRunning)

if (Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue) {
    Write-Error 'Playnite is already running. Close it first - this script starts and stops its own instance.'
    return
}

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class MemT {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    [DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr h);
    [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct WINDOWPLACEMENT {
        public int length; public int flags; public int showCmd;
        public POINT ptMinPosition; public POINT ptMaxPosition; public RECT rcNormalPosition;
    }
    [StructLayout(LayoutKind.Sequential)] public struct MEMORY_PRIORITY_INFORMATION { public uint MemoryPriority; }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetProcessInformation(IntPtr h, int cls, ref MEMORY_PRIORITY_INFORMATION info, int size);

    public static bool SetMemoryPriority(IntPtr h, uint priority) {
        var info = new MEMORY_PRIORITY_INFORMATION { MemoryPriority = priority };
        return SetProcessInformation(h, 0, ref info, Marshal.SizeOf(typeof(MEMORY_PRIORITY_INFORMATION)));
    }

    public static IntPtr FindMainWindow(uint pid) {
        IntPtr best = IntPtr.Zero; long bestArea = 0;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && GetWindow(h, 4) == IntPtr.Zero) {
                var wp = new WINDOWPLACEMENT();
                wp.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
                if (GetWindowPlacement(h, ref wp)) {
                    int w = wp.rcNormalPosition.R - wp.rcNormalPosition.L;
                    int ht = wp.rcNormalPosition.B - wp.rcNormalPosition.T;
                    if (w >= 1200 && ht >= 700) {
                        long area = (long)w * ht;
                        if (area > bestArea) { bestArea = area; best = h; }
                    }
                }
            }
            return true;
        }, IntPtr.Zero);
        return best;
    }
}
"@

$log = Join-Path $env:APPDATA 'Playnite\playnite.log'
$exe = Join-Path $env:LOCALAPPDATA 'Playnite\Playnite.FullscreenApp.exe'
$outDir = Split-Path $PSCommandPath

function Snap([string]$label) {
    $p = Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue
    if (-not $p) { Write-Host "$label : none"; return }
    $ws = ($p | Measure-Object WorkingSet64 -Sum).Sum
    $priv = ($p | Measure-Object PrivateMemorySize64 -Sum).Sum
    $hw = Get-CimInstance Win32_OperatingSystem
    Write-Host ("{0,-20} WS={1,5} MB   private/commit={2,5} MB   physical free={3,6} MB" -f `
        $label, [math]::Round($ws/1MB), [math]::Round($priv/1MB), [math]::Round($hw.FreePhysicalMemory/1KB))
}

function Trim-All([string]$label) {
    foreach ($proc in (Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue)) {
        try {
            [MemT]::EmptyWorkingSet($proc.Handle) | Out-Null
            $h = [MemT]::OpenProcess(0x0100 -bor 0x0400, $false, $proc.Id)
            if ($h -ne [IntPtr]::Zero) { [MemT]::SetMemoryPriority($h, 1) | Out-Null }
        } catch { Write-Host "  skip $($proc.Name): $($_.Exception.Message)" }
    }
    if ($label) { Write-Host "$label done" }
}

$before = (Get-Content $log).Count
$p = Start-Process -FilePath $exe -ArgumentList '--hidesplashscreen' -PassThru
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
    if ((Get-Content $log | Select-Object -Skip $before) -match 'Render screen') { break }
}
Start-Sleep -Seconds 5
Snap '1 visible, idle'

$hwnd = [MemT]::FindMainWindow([uint32]$p.Id)
if ($hwnd -eq [IntPtr]::Zero) { Write-Error 'main window not found'; return }
"main window: $hwnd"

# Minimize -> helper hides it
[MemT]::ShowWindow($hwnd, 6) | Out-Null
Start-Sleep -Seconds 3
$hidden = -not [MemT]::IsWindowVisible($hwnd)
"hidden by helper: $hidden"
Snap '2 hidden in tray'

Trim-All '3 trim'
Start-Sleep -Seconds 2
Snap '3 trimmed'
Start-Sleep -Seconds 10
Snap '4 trimmed +15s'

# ---- restore ----
$sw = [System.Diagnostics.Stopwatch]::StartNew()
[MemT]::ShowWindow($hwnd, 9) | Out-Null
[MemT]::SetForegroundWindow($hwnd) | Out-Null
while ($sw.Elapsed.TotalSeconds -lt 15) {
    if ([MemT]::IsWindowVisible($hwnd) -and -not [MemT]::IsIconic($hwnd)) { break }
    Start-Sleep -Milliseconds 10
}
"window shown after {0} ms" -f [math]::Round($sw.Elapsed.TotalMilliseconds)

$res = [IntPtr]::Zero
$t2 = [System.Diagnostics.Stopwatch]::StartNew()
[void][MemT]::SendMessageTimeout($hwnd, 0, [IntPtr]::Zero, [IntPtr]::Zero, 2, 15000, [ref]$res)
"UI pump answered WM_NULL after {0} ms (total {1} ms)" -f [math]::Round($t2.Elapsed.TotalMilliseconds), [math]::Round($sw.Elapsed.TotalMilliseconds)
Start-Sleep -Seconds 4
Snap '5 restored +4s'

# does it still draw? PrintWindow captures the window itself, not the screen.
$r = New-Object MemT+RECT
[void][MemT]::GetWindowRect($hwnd, [ref]$r)
$w = $r.R - $r.L; $h2 = $r.B - $r.T
$bmp = New-Object System.Drawing.Bitmap $w, $h2
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
$ok = [MemT]::PrintWindow($hwnd, $hdc, 2)
$g.ReleaseHdc($hdc); $g.Dispose()
$path = Join-Path $outDir 'playnite-after-trim.png'
$bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
"PrintWindow ok=$ok  size=${w}x${h2}  -> $path"

# helper's own footprint
$helper = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*-File*PlayniteTray.ps1*' } | Select-Object -First 1
if ($helper) {
    $hp = Get-Process -Id $helper.ProcessId
    "tray helper before trim: WS=$([math]::Round($hp.WorkingSet64/1MB)) MB"
    [MemT]::EmptyWorkingSet($hp.Handle) | Out-Null
    Start-Sleep -Seconds 2
    $hp.Refresh()
    "tray helper after trim : WS=$([math]::Round($hp.WorkingSet64/1MB)) MB"
}

if (-not $KeepRunning) {
    Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() | Out-Null }
    Start-Sleep -Seconds 4
    Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force }
    'closed'
}
