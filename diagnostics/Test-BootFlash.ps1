# Test-BootFlash.ps1
# Decides whether the boot-time hide is actually *seen*.
#
# IsWindowVisible=True only means the WS_VISIBLE style bit is set; DWM may never
# composite a frame in that time, which would make the "flash" invisible. This
# samples the screen during a simulated login and records, per sample, whether the
# window reports visible plus the mean brightness of the captured region.
# Frames are saved so they can be compared by eye:
#   flash-baseline.png   desktop before launch
#   flash-visible-*.png  captured while the window reported WS_VISIBLE
#   flash-restored.png   Playnite shown normally (reference for "really visible")
param([int]$Seconds = 22)

Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public class Flash {
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

    public static Bitmap Grab(int x, int y, int w, int h) {
        var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp)) {
            g.CopyFromScreen(x, y, 0, 0, new Size(w, h), CopyPixelOperation.SourceCopy);
        }
        return bmp;
    }

    public static double Mean(Bitmap bmp) {
        var data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            int stride = data.Stride;
            byte[] row = new byte[stride];
            long sum = 0; long n = 0;
            for (int yy = 0; yy < bmp.Height; yy += 2) {
                Marshal.Copy(IntPtr.Add(data.Scan0, yy * stride), row, 0, stride);
                for (int xx = 0; xx < bmp.Width * 4; xx += 16) {
                    sum += (row[xx] + row[xx + 1] + row[xx + 2]) / 3;
                    n++;
                }
            }
            return n == 0 ? 0 : (double)sum / n;
        } finally { bmp.UnlockBits(data); }
    }

    public static void Save(Bitmap bmp, string path) { bmp.Save(path, ImageFormat.Png); }
}
"@

$dir = Split-Path $PSCommandPath
$repo = Split-Path $dir
$csv = Join-Path $dir 'flash-samples.csv'
$vbs = Join-Path $repo 'scripts\PlayniteTray.vbs'
$trayLog = Join-Path $env:TEMP 'playnite-tray.log'
$desktop = Join-Path $env:LOCALAPPDATA 'Playnite\Playnite.DesktopApp.exe'
$exe = Join-Path $env:LOCALAPPDATA 'Playnite\Playnite.FullscreenApp.exe'

if (Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue) { Write-Error 'Close Playnite first.'; return }

Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*-File*PlayniteTray.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -Filter "Name = 'wscript.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*PlayniteTray.vbs*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
Remove-Item $trayLog, $csv -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $dir 'flash-*.png') -Force -ErrorAction SilentlyContinue

Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + $vbs + '"')
Start-Sleep -Seconds 2

$region = @{ X = 660; Y = 360; W = 600; H = 360 }

$baseBmp = [Flash]::Grab($region.X, $region.Y, $region.W, $region.H)
$base = [Flash]::Mean($baseBmp)
[Flash]::Save($baseBmp, (Join-Path $dir 'flash-baseline.png'))
$baseBmp.Dispose()
"desktop baseline brightness: $([math]::Round($base, 2))"
"launching like the Startup shortcut does (desktop stub)..."

$sw = [System.Diagnostics.Stopwatch]::StartNew()
Start-Process -FilePath $desktop -ArgumentList '--hidesplashscreen' | Out-Null

$rows = New-Object System.Collections.Generic.List[string]
$visibleFrames = 0
$lastVisible = $false

while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    $t = [math]::Round($sw.Elapsed.TotalMilliseconds)
    $p = Get-Process -Name 'Playnite.FullscreenApp' -ErrorAction SilentlyContinue | Select-Object -First 1
    $hwnd = [IntPtr]::Zero
    if ($p) { $hwnd = [Flash]::Find([uint32]$p.Id) }

    $vis = ($hwnd -ne [IntPtr]::Zero) -and [Flash]::IsWindowVisible($hwnd)
    $bmp = [Flash]::Grab($region.X, $region.Y, $region.W, $region.H)
    $b = [Flash]::Mean($bmp)
    $rows.Add("$t,$([int]$vis),$([math]::Round($b, 2)),$([math]::Round($b - $base, 2))")

    if ($vis -and -not $lastVisible) {
        [Flash]::Save($bmp, (Join-Path $dir "flash-visible-$t.png"))
        $visibleFrames++
    }
    if ($vis) { $visibleFrames++ }
    $bmp.Dispose()
    $lastVisible = $vis
}

$rows | Set-Content -Path $csv
$data = Import-Csv $csv -Header t, vis, bright, delta
$visRows = @($data | Where-Object { $_.vis -eq '1' })

"sampled $($rows.Count) frames over $Seconds s  (desktop baseline $([math]::Round($base, 2)))"
"max brightness delta overall : $(($data | Measure-Object -Property delta -Maximum).Maximum)"
"samples with WS_VISIBLE      : $($visRows.Count)"
if ($visRows.Count -gt 0) {
    $first = $visRows | Select-Object -First 1
    $last = $visRows | Select-Object -Last 1
    "WS_VISIBLE span              : $($first.t) - $($last.t) ms ($([int]$last.t - [int]$first.t) ms)"
    "brightness while WS_VISIBLE  : $(($visRows | Measure-Object -Property bright -Minimum).Minimum) .. $(($visRows | Measure-Object -Property bright -Maximum).Maximum)"
}
"frames saved                 : $visibleFrames"

"--- now show Playnite for real (reference frame) ---"
Start-Process -FilePath $exe -ArgumentList '--hidesplashscreen' | Out-Null
Start-Sleep -Seconds 6
$refBmp = [Flash]::Grab($region.X, $region.Y, $region.W, $region.H)
$refMean = [Flash]::Mean($refBmp)
[Flash]::Save($refBmp, (Join-Path $dir 'flash-restored.png'))
$refBmp.Dispose()
"reference (really visible) brightness: $([math]::Round($refMean, 2))  contrast vs desktop: $([math]::Round($refMean - $base, 2))"

"--- helper log ---"
Get-Content $trayLog -ErrorAction SilentlyContinue

Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() | Out-Null }
Start-Sleep -Seconds 4
Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force }
'cleaned up'
