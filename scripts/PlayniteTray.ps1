# PlayniteTray.ps1
# Tray icon + watcher for Playnite fullscreen.
#
# Playnite's fullscreen app has no tray support (only the desktop app does), and its
# "Minimize" puts the window on the taskbar. This helper:
#   * polls for the Playnite fullscreen window being minimized,
#   * hides it (SW_HIDE) so it leaves the taskbar and Alt+Tab,
#   * trims its working set so the hidden app drops to a few MB of resident RAM,
#   * shows a tray icon whose menu can restore, start or quit Playnite.
#
# Memory: EmptyWorkingSet pushes Playnite's pages to the pagefile/standby list and
# sets low memory priority so Windows keeps them out. Private commit is unchanged
# (it's a resident app), but resident RAM goes ~400 MB -> ~20 MB while hidden.
# Trimmed pages fault back in on restore in ~60 ms, so it stays instant.
#
# Log: %TEMP%\playnite-tray.log

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class PTrayNative {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);

    [DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr h);
    [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetProcessInformation(IntPtr h, int cls, ref MEMORY_PRIORITY_INFORMATION info, int size);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct WINDOWPLACEMENT {
        public int length; public int flags; public int showCmd;
        public POINT ptMinPosition; public POINT ptMaxPosition;
        public RECT rcNormalPosition;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct MEMORY_PRIORITY_INFORMATION { public uint MemoryPriority; }

    // 1 = lowest (Windows trims these pages first), 5 = normal
    public static bool SetMemoryPriority(IntPtr h, uint priority) {
        var info = new MEMORY_PRIORITY_INFORMATION { MemoryPriority = priority };
        return SetProcessInformation(h, 0, ref info, Marshal.SizeOf(typeof(MEMORY_PRIORITY_INFORMATION)));
    }

    public static IntPtr OpenForInfo(int pid) {
        return OpenProcess(0x0200 | 0x0400, false, pid); // SET_INFORMATION | QUERY_INFORMATION
    }

    // Largest unparented top-level window of the process, including hidden ones
    // (a minimized window reports rcNormalPosition, not the -32000 icon rect).
    public static IntPtr FindMainWindow(uint pid) {
        IntPtr best = IntPtr.Zero;
        long bestArea = 0;
        EnumWindows((h, l) => {
            uint p;
            GetWindowThreadProcessId(h, out p);
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

$ErrorActionPreference = 'Stop'

# One instance only
$mutex = New-Object System.Threading.Mutex($false, 'Global\PlayniteTrayHelper')
if (-not $mutex.WaitOne(0)) { return }
$script:mutex = $mutex

$fullscreenExe = Join-Path $env:LOCALAPPDATA 'Playnite\Playnite.FullscreenApp.exe'
$logPath = Join-Path $env:TEMP 'playnite-tray.log'

function Write-Log([string]$msg) {
    try { "$(Get-Date -Format 'HH:mm:ss') $msg" | Add-Content -Path $logPath -Encoding utf8 } catch { }
}

function Get-PlayniteProcess {
    Get-Process -Name 'Playnite.FullscreenApp' -ErrorAction SilentlyContinue | Select-Object -First 1
}

# Pushes resident pages out and asks Windows to keep them out (priority 1).
function Trim-Playnite([uint32]$priority) {
    foreach ($proc in (Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue)) {
        try {
            [PTrayNative]::EmptyWorkingSet($proc.Handle) | Out-Null
            $h = [PTrayNative]::OpenForInfo($proc.Id)
            if ($h -ne [IntPtr]::Zero) { [PTrayNative]::SetMemoryPriority($h, $priority) | Out-Null }
        } catch { }
    }
}

function Trim-Self {
    try { [PTrayNative]::EmptyWorkingSet((Get-Process -Id $PID).Handle) | Out-Null } catch { }
}

function Show-Playnite {
    $p = Get-PlayniteProcess
    if (-not $p) {
        if (Test-Path -LiteralPath $fullscreenExe) {
            Start-Process -FilePath $fullscreenExe -ArgumentList '--hidesplashscreen'
            Write-Log 'started Playnite (was not running)'
        }
        return
    }

    # Back to normal priority before it becomes visible, so Windows stops trimming it.
    Trim-Playnite 5

    $p.Refresh()
    $hwnd = $p.MainWindowHandle
    if ($hwnd -eq [IntPtr]::Zero) { $hwnd = [PTrayNative]::FindMainWindow([uint32]$p.Id) }
    if ($hwnd -eq [IntPtr]::Zero) { return }
    # SW_RESTORE also un-hides a window hidden with SW_HIDE
    [PTrayNative]::ShowWindow($hwnd, 9) | Out-Null
    [PTrayNative]::SetForegroundWindow($hwnd) | Out-Null
    $script:hidden = $false
    Write-Log 'restored window'
}

function Hide-MinimizedPlaynite {
    $p = Get-PlayniteProcess
    if (-not $p) {
        $script:hidden = $false
        return
    }
    $p.Refresh()
    $hwnd = $p.MainWindowHandle
    if ($hwnd -eq [IntPtr]::Zero) { $hwnd = [PTrayNative]::FindMainWindow([uint32]$p.Id) }
    if ($hwnd -eq [IntPtr]::Zero) { return }

    # Minimized and still visible => move it off the taskbar into the tray
    if ([PTrayNative]::IsIconic($hwnd) -and [PTrayNative]::IsWindowVisible($hwnd)) {
        [PTrayNative]::ShowWindow($hwnd, 0) | Out-Null
        Trim-Playnite 1
        Trim-Self
        $script:hidden = $true
        $ws = [math]::Round(((Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue) |
            Measure-Object WorkingSet64 -Sum).Sum / 1MB)
        Write-Log "minimized -> hidden to tray, trimmed (Playnite WS now ${ws} MB)"
    }
}

# ---- UI ----
$notify = New-Object System.Windows.Forms.NotifyIcon
try {
    $notify.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($fullscreenExe)
} catch {
    $notify.Icon = [System.Drawing.SystemIcons]::Application
}
$notify.Text = 'Playnite'
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$itemShow = $menu.Items.Add('Show Playnite')
$itemShow.Font = New-Object System.Drawing.Font($itemShow.Font, [System.Drawing.FontStyle]::Bold)
$itemQuit = $menu.Items.Add('Quit Playnite')
$menu.Items.Add('-') | Out-Null
$itemExit = $menu.Items.Add('Exit tray helper')

$itemShow.add_Click({ Show-Playnite })
$itemQuit.add_Click({
    $p = Get-PlayniteProcess
    if ($p) { $p.CloseMainWindow() | Out-Null; Write-Log 'quit requested' }
})
$itemExit.add_Click({
    $notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

$menu.add_Opening({
    $p = Get-PlayniteProcess
    $itemShow.Text = if ($p) { 'Show Playnite' } else { 'Start Playnite' }
    $itemQuit.Enabled = [bool]$p
})

$notify.add_MouseDoubleClick({ Show-Playnite })
$notify.ContextMenuStrip = $menu

$script:hidden = $false

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 700
$timer.add_Tick({ try { Hide-MinimizedPlaynite } catch { Write-Log "tick error: $_" } })
$timer.Start()

# Keep it small while it sits in the tray (WPF slowly faults pages back in).
$trimTimer = New-Object System.Windows.Forms.Timer
$trimTimer.Interval = 30000
$trimTimer.add_Tick({
    try {
        if ($script:hidden -and (Get-PlayniteProcess)) {
            Trim-Playnite 1
            Trim-Self
        }
    } catch { }
})
$trimTimer.Start()

Write-Log 'tray helper started'
[System.Windows.Forms.Application]::Run()

# cleanup
$timer.Stop()
$trimTimer.Stop()
$notify.Visible = $false
$notify.Dispose()
$script:mutex.ReleaseMutex()
$script:mutex.Dispose()
