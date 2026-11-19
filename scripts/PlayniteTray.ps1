# PlayniteTray.ps1
# Tray icon + watcher for Playnite fullscreen.
#
# Playnite's fullscreen app has no tray support (only the desktop app does), and its
# "Minimize" puts the window on the taskbar. This helper:
#   * hides the window (SW_HIDE) when Playnite is minimized, so it leaves the taskbar,
#   * hides the window at login if Playnite booted to fullscreen (see below),
#   * trims its working set so a hidden Playnite is nearly free in RAM,
#   * shows a tray icon whose menu can restore, start or quit Playnite.
#
# Boot behaviour: Playnite's own "Start on boot" launches the desktop stub, which
# relaunches the fullscreen app. Playnite has no "start fullscreen minimized" option
# (StartOnBootClosedToTray only affects the desktop window), so the window appears
# visibly after ~9 s. This helper watches that first instance and hides it the moment
# its window is shown, using a WinEvent hook (EVENT_OBJECT_SHOW) so it never reaches
# the screen for more than a frame. Playnite's boot setting stays untouched.
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

// Hides the Playnite window the instant Playnite shows it, so a boot launch never
// becomes visible. EVENT_OBJECT_SHOW is delivered out-of-context, so the callback
// needs a thread that pumps messages. That thread is dedicated and owned by this
// class: a WinForms timer or anything else on the UI thread can be busy when the
// event arrives, which is what made an earlier version fire late (or miss entirely).
//
// One system-wide hook is installed for the process lifetime; WatchPid selects the
// process to hide. Events from other processes cost one early return.
public class PTrayWatch {
    public delegate void WinEventProc(IntPtr hHook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint evMin, uint evMax, IntPtr hmod, WinEventProc cb, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder sb, int max);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG msg, IntPtr hwnd, uint min, uint max);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG msg);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG msg);

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct MSG {
        public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam;
        public uint time; public POINT pt;
    }

    static WinEventProc callback;
    static IntPtr hook = IntPtr.Zero;

    // Set to the pid to hide; 0 means "ignore everything".
    public static volatile uint WatchPid;
    public static volatile bool Hid;
    public static IntPtr Target;

    // Set PLAYNITE_TRAY_TRACE=1 to log every event that reaches the hook.
    public static volatile bool TraceOn;
    public static readonly System.Collections.Concurrent.ConcurrentQueue<string> TraceLog =
        new System.Collections.Concurrent.ConcurrentQueue<string>();
    public static bool Installed { get { return hook != IntPtr.Zero; } }

    public static bool Start() {
        if (hook != IntPtr.Zero) return true;
        var t = new System.Threading.Thread(Loop) { IsBackground = true, Name = "PTrayWinEvent" };
        t.Start();
        for (int i = 0; i < 100 && hook == IntPtr.Zero; i++) System.Threading.Thread.Sleep(10);
        return hook != IntPtr.Zero;
    }

    static void Loop() {
        callback = OnShow;
        // EVENT_OBJECT_SHOW = 0x8002, WINEVENT_OUTOFCONTEXT = 0, WINEVENT_SKIPOWNPROCESS = 0x0002
        hook = SetWinEventHook(0x8002, 0x8002, IntPtr.Zero, callback, 0, 0, 0x0000 | 0x0002);
        if (hook == IntPtr.Zero) return;
        while (true) {
            MSG msg;
            if (GetMessage(out msg, IntPtr.Zero, 0, 0) <= 0) break;
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }
    }

    static void OnShow(IntPtr hHook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time) {
        uint watch = WatchPid;
        if (watch == 0) return;
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        if (pid != watch) return;

        // Only WPF windows (Playnite's UI); skips native helper/CEF windows.
        var cls = new System.Text.StringBuilder(256);
        GetClassName(hwnd, cls, 256);

        if (TraceOn) {
            TraceLog.Enqueue(string.Format(
                "idObj={0} child={1} owner={2} visible={3} class='{4}'",
                idObject, idChild, GetWindow(hwnd, 4), IsWindowVisible(hwnd), cls));
        }

        if (idObject != 0 || idChild != 0) return;                 // OBJID_WINDOW only
        if (GetWindow(hwnd, 4) != IntPtr.Zero) return;             // GW_OWNER: skip popups
        if (!IsWindowVisible(hwnd)) return;
        if (!cls.ToString().StartsWith("HwndWrapper[")) return;

        ShowWindow(hwnd, 0);                                       // SW_HIDE
        Target = hwnd;
        Hid = true;
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
$script:startedAt = Get-Date

function Write-Log([string]$msg) {
    try { "$(Get-Date -Format 'HH:mm:ss') $msg" | Add-Content -Path $logPath -Encoding utf8 } catch { }
}

function Get-PlayniteProcess {
    Get-Process -Name 'Playnite.FullscreenApp' -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Get-MainWindow($proc) {
    if (-not $proc) { return [IntPtr]::Zero }
    $proc.Refresh()
    $hwnd = $proc.MainWindowHandle
    if ($hwnd -eq [IntPtr]::Zero) { $hwnd = [PTrayNative]::FindMainWindow([uint32]$proc.Id) }
    return $hwnd
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

function Set-Hidden {
    $script:hidden = $true
    $script:hiddenSince = Get-Date
    $script:graceUntil = (Get-Date).AddSeconds(10)
    $script:pendingTrimAt = (Get-Date).AddSeconds(8)
}

function Show-Playnite {
    # The user asked for it explicitly: stop any boot-time hiding.
    $script:bootWatch = $false
    [PTrayWatch]::WatchPid = [uint32]0

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

    $hwnd = Get-MainWindow $p
    if ($hwnd -eq [IntPtr]::Zero) { return }
    # SW_RESTORE also un-hides a window hidden with SW_HIDE
    [PTrayNative]::ShowWindow($hwnd, 9) | Out-Null
    [PTrayNative]::SetForegroundWindow($hwnd) | Out-Null
    $script:hidden = $false
    Write-Log 'restored window'
}

function Stop-BootWatch([string]$why) {
    $script:bootWatch = $false
    $watchTimer.Stop()
    [PTrayWatch]::WatchPid = [uint32]0
    if ($why) { Write-Log "boot watch: $why" }
}

# Keeps the window hidden while Playnite is starting up at login.
function Invoke-BootWatch {
    if ([PTrayWatch]::TraceOn) {
        $item = ''
        while ([PTrayWatch]::TraceLog.TryDequeue([ref]$item)) { Write-Log "trace: $item" }
    }

    if (-not $script:bootWatch) { $watchTimer.Stop(); [PTrayWatch]::WatchPid = [uint32]0; return }

    if ((Get-Date) -gt $script:bootWatchUntil) { Stop-BootWatch 'gave up (no window in time)'; return }

    $p = Get-PlayniteProcess
    if (-not $p) { return }

    if ($p.Id -ne $script:watchPid) {
        # Playnite's boot path starts the app within seconds of the helper. A process
        # started much later is you launching it on purpose - leave that one alone.
        $sinceHelper = ($p.StartTime - $script:startedAt).TotalSeconds
        if ($sinceHelper -gt 45) {
            Stop-BootWatch "not hiding a manual launch ($([math]::Round($sinceHelper)) s after login)"
            return
        }

        $script:watchPid = $p.Id
        [PTrayWatch]::Hid = $false
        [PTrayWatch]::WatchPid = [uint32]$p.Id
        Write-Log "boot watch: watching pid $($p.Id)"
    }

    $hwnd = Get-MainWindow $p
    if ($hwnd -eq [IntPtr]::Zero) { return }
    $visible = [PTrayNative]::IsWindowVisible($hwnd)
    $iconic = [PTrayNative]::IsIconic($hwnd)

    if (-not $script:hidden) {
        # Normally the show hook already hid it; this covers a window that appeared
        # before the hook could see it.
        if ([PTrayWatch]::Hid -or ($visible -and -not $iconic)) {
            if (-not [PTrayWatch]::Hid) {
                [PTrayNative]::ShowWindow($hwnd, 0) | Out-Null
                Write-Log 'boot watch: hid window after it appeared'
            }
            Set-Hidden
            Write-Log 'boot watch: hidden to tray'
        }
        return
    }

    # Hidden: hold it down for a short grace window, then stand down.
    if ($visible -and -not $iconic) {
        if ((Get-Date) -lt $script:graceUntil) {
            [PTrayNative]::ShowWindow($hwnd, 0) | Out-Null
            Write-Log 'boot watch: re-hidden during grace'
        } else {
            $script:hidden = $false
            $script:pendingTrimAt = $null
            Trim-Playnite 5
            Stop-BootWatch 'window restored, standing down'
        }
        return
    }

    if ((Get-Date) -ge $script:graceUntil) { Stop-BootWatch 'finished' }
}

function Update-State {
    $p = Get-PlayniteProcess
    if (-not $p) { $script:hidden = $false; return }
    $hwnd = Get-MainWindow $p
    if ($hwnd -eq [IntPtr]::Zero) { return }

    $visible = [PTrayNative]::IsWindowVisible($hwnd)
    $iconic = [PTrayNative]::IsIconic($hwnd)

    # Minimized and still visible => move it off the taskbar into the tray
    if ($iconic -and $visible) {
        [PTrayNative]::ShowWindow($hwnd, 0) | Out-Null
        Set-Hidden
        Trim-Playnite 1
        Trim-Self
        $ws = [math]::Round(((Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue) |
            Measure-Object WorkingSet64 -Sum).Sum / 1MB)
        Write-Log "minimized -> hidden to tray, trimmed (Playnite WS now ${ws} MB)"
        return
    }

    # Restored behind our back (Playnite shortcut sends "Focus", which un-hides it)
    if ($visible -and -not $iconic -and $script:hidden) {
        if ((Get-Date) -ge $script:graceUntil) {
            $script:hidden = $false
            $script:pendingTrimAt = $null
            Trim-Playnite 5
            Write-Log 'window became visible, trim state reset'
        }
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
$script:hiddenSince = $null
$script:graceUntil = (Get-Date).AddSeconds(-1)
$script:pendingTrimAt = $null
$script:watchPid = 0
$script:bootWatch = $false
$script:bootWatchUntil = (Get-Date).AddSeconds(90)

# Only treat an instance that just started (or is about to start) as the boot one.
# A helper restarted mid-session must not hide a window you are using.
$existing = Get-PlayniteProcess
$script:bootWatch = $true
if ($existing) {
    $age = ((Get-Date) - $existing.StartTime).TotalSeconds
    if ($age -ge 30) {
        # Long-running instance: never hide it now, just adopt its current state.
        $script:bootWatch = $false
        $hwnd = Get-MainWindow $existing
        $visible = ($hwnd -ne [IntPtr]::Zero) -and [PTrayNative]::IsWindowVisible($hwnd)
        if (-not $visible) {
            $script:hidden = $true
            $script:graceUntil = (Get-Date).AddSeconds(-1)
            Trim-Playnite 1
            Write-Log 'adopted a hidden instance'
        }
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 700
$timer.add_Tick({
    try {
        Update-State
        if ($script:pendingTrimAt -and (Get-Date) -ge $script:pendingTrimAt) {
            $script:pendingTrimAt = $null
            Trim-Playnite 1
            Trim-Self
        }
    } catch { Write-Log "tick error: $_" }
})
$timer.Start()

$watchTimer = New-Object System.Windows.Forms.Timer
$watchTimer.Interval = 150
$watchTimer.add_Tick({ try { Invoke-BootWatch } catch { Write-Log "watch error: $_" } })
if ($script:bootWatch) {
    $watchTimer.Start()
    Write-Log 'boot watch: armed'
} else {
    Write-Log 'boot watch: not needed (Playnite already in use)'
}

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

$traceEnv = $env:PLAYNITE_TRAY_TRACE
if ($traceEnv) { [PTrayWatch]::TraceOn = $true; Write-Log "trace enabled (PLAYNITE_TRAY_TRACE=$traceEnv)" }
if (-not [PTrayWatch]::Start()) { Write-Log 'warning: show-event hook unavailable (timer fallback only)' }

Write-Log 'tray helper started'
[System.Windows.Forms.Application]::Run()

# cleanup
$timer.Stop()
$watchTimer.Stop()
$trimTimer.Stop()
[PTrayWatch]::WatchPid = [uint32]0
$notify.Visible = $false
$notify.Dispose()
$script:mutex.ReleaseMutex()
$script:mutex.Dispose()
