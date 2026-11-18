# Test-TrayTrim.ps1
# Restarts the tray helper with the new trim logic and verifies:
#   visible -> hidden+trimmed -> restored, with the theme still drawing.
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class TT {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WP p);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint f, uint t, out IntPtr r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct WP {
        public int length; public int flags; public int showCmd;
        public POINT ptMin; public POINT ptMax; public RECT rcNormal;
    }
    public static IntPtr Find(uint pid) {
        IntPtr best = IntPtr.Zero; long area = 0;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && GetWindow(h, 4) == IntPtr.Zero) {
                var wp = new WP(); wp.length = Marshal.SizeOf(typeof(WP));
                if (GetWindowPlacement(h, ref wp)) {
                    int w = wp.rcNormal.R - wp.rcNormal.L, ht = wp.rcNormal.B - wp.rcNormal.T;
                    if (w >= 1200 && ht >= 700 && (long)w * ht > area) { area = (long)w * ht; best = h; }
                }
            }
            return true;
        }, IntPtr.Zero);
        return best;
    }
}
"@

$dir = Split-Path $PSCommandPath
$repo = Split-Path $dir
$trayVbs = Join-Path $repo 'scripts\PlayniteTray.vbs'
$log = Join-Path $env:APPDATA 'Playnite\playnite.log'
$exe = Join-Path $env:LOCALAPPDATA 'Playnite\Playnite.FullscreenApp.exe'
$trayLog = Join-Path $env:TEMP 'playnite-tray.log'

function Helper { Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*-File*PlayniteTray.ps1*' } | Select-Object -First 1 }
function WsSum { [math]::Round(((Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue) | Measure-Object WorkingSet64 -Sum).Sum / 1MB) }

# restart helper so the new code is live
Helper | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
Remove-Item $trayLog -Force -ErrorAction SilentlyContinue
Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + $trayVbs + '"')
Start-Sleep -Seconds 3
$h = Helper
"helper running: $([bool]$h) $(if ($h) { "PID $($h.ProcessId)" })"
if (-not $h) { Write-Error 'helper did not start'; return }
"helper WS at start: $([math]::Round((Get-Process -Id $h.ProcessId).WorkingSet64/1MB)) MB"

$before = (Get-Content $log).Count
$p = Start-Process -FilePath $exe -ArgumentList '--hidesplashscreen' -PassThru
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
    if ((Get-Content $log | Select-Object -Skip $before) -match 'Render screen') { break }
}
Start-Sleep -Seconds 5
"visible:     Playnite WS=$((WsSum)) MB   helper WS=$([math]::Round((Get-Process -Id $h.ProcessId).WorkingSet64/1MB)) MB"

$hwnd = [TT]::Find([uint32]$p.Id)
[TT]::ShowWindow($hwnd, 6) | Out-Null
Start-Sleep -Seconds 4
"hidden:      Playnite WS=$((WsSum)) MB   helper WS=$([math]::Round((Get-Process -Id $h.ProcessId).WorkingSet64/1MB)) MB"

Start-Sleep -Seconds 32
"after 36s:   Playnite WS=$((WsSum)) MB   helper WS=$([math]::Round((Get-Process -Id $h.ProcessId).WorkingSet64/1MB)) MB"

$sw = [System.Diagnostics.Stopwatch]::StartNew()
[TT]::ShowWindow($hwnd, 9) | Out-Null
[TT]::SetForegroundWindow($hwnd) | Out-Null
while ($sw.Elapsed.TotalSeconds -lt 15) {
    if ([TT]::IsWindowVisible($hwnd) -and -not [TT]::IsIconic($hwnd)) { break }
    Start-Sleep -Milliseconds 10
}
"restored in $([math]::Round($sw.Elapsed.TotalMilliseconds)) ms"
$res = [IntPtr]::Zero
[void][TT]::SendMessageTimeout($hwnd, 0, [IntPtr]::Zero, [IntPtr]::Zero, 2, 15000, [ref]$res)
Start-Sleep -Seconds 4
"after restore: Playnite WS=$((WsSum)) MB"

$bmp = New-Object System.Drawing.Bitmap 1920, 1080
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
$ok = [TT]::PrintWindow($hwnd, $hdc, 2)
$g.ReleaseHdc($hdc); $g.Dispose()
$out = Join-Path $dir 'playnite-trayrestore.png'
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
"PrintWindow ok=$ok -> $out"

"---- tray log ----"
Get-Content $trayLog -ErrorAction SilentlyContinue

Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() | Out-Null }
Start-Sleep -Seconds 4
Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force }
'closed'
