# PlayniteTray.ps1
# Tray icon + watcher for Playnite fullscreen.
#
# Usage:
#   PlayniteTray.ps1                 run the tray helper (normal use, started by the VBS)
#   PlayniteTray.ps1 -Action status  print the current state and exit
#   PlayniteTray.ps1 -Action show    restore Playnite (or start it) and exit
#   PlayniteTray.ps1 -Action quit    stop Playnite (asks nicely, then forces) and exit
#   PlayniteTray.ps1 -Action restart quit + start and exit
# The action mode exists so the tray behaviour can be scripted and tested without
# clicking menus.
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
# Failsafe: a Playnite that has no window at all but still runs is not "hidden in the
# tray", it is wedged - typically because Windows started a shutdown and went to sleep
# before Playnite finished exiting. Such a process cannot be terminated any more and it
# holds Playnite's single-instance lock, so every new launch dies with "another instance
# is already running". The helper detects that (no window for 20 s), tries to clear it,
# restarts Playnite, and tells you to reboot if the process refuses to die.
#
# The reverse case is prevented too: on session end the helper asks Playnite to close
# (WM_CLOSE) and forces it after 3 s, so it is never left half-exited.
#
# Log: %TEMP%\playnite-tray.log

param(
    [ValidateSet('run', 'status', 'show', 'quit', 'restart')]
    [string]$Action = 'run'
)

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
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);

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

$fullscreenExe = Join-Path $env:LOCALAPPDATA 'Playnite\Playnite.FullscreenApp.exe'
$logPath = Join-Path $env:TEMP 'playnite-tray.log'
$script:startedAt = Get-Date

function Write-Log([string]$msg) {
    try { "$(Get-Date -Format 'HH:mm:ss') $msg" | Add-Content -Path $logPath -Encoding utf8 } catch { }
}

function Get-PlayniteProcess {
    $all = @(Get-Process -Name 'Playnite.FullscreenApp' -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) { return $null }
    if ($all.Count -gt 1) {
        # Prefer an instance that owns a window; otherwise the newest one (a wedged
        # process left over from a broken shutdown has no window and must not win).
        foreach ($proc in $all) {
            if ([PTrayNative]::FindMainWindow([uint32]$proc.Id) -ne [IntPtr]::Zero) { return $proc }
        }
        return ($all | Sort-Object StartTime -Descending | Select-Object -First 1)
    }
    return $all[0]
}

# Process.HasExited is true for a process that is stuck inside its own exit, even though
# the process object still exists and keeps blocking new launches. Only the process list
# tells the truth.
function Test-PlayniteExists([int]$ProcessId) {
    return [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
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

function Show-Balloon([string]$title, [string]$text) {
    if (-not $script:notify) { return }
    try {
        $script:notify.ShowBalloonTip(10000, $title, $text, [System.Windows.Forms.ToolTipIcon]::Warning)
    } catch { }
}

function Start-Playnite {
    if (-not (Test-Path -LiteralPath $fullscreenExe)) {
        Write-Log 'cannot start Playnite - exe not found'
        return $false
    }
    Start-Process -FilePath $fullscreenExe -ArgumentList '--hidesplashscreen'
    $script:noWindowSince = Get-Date
    $script:stale = $false
    Write-Log 'started Playnite'
    return $true
}

# Asks Playnite to close (WM_CLOSE, which also works while it is hidden), forces it if
# it ignores that, and reports whether the process is really gone.
function Stop-Playnite([int]$graceSeconds = 6) {
    $p = Get-PlayniteProcess
    if (-not $p) { return $true }
    $procId = $p.Id

    $hwnd = Get-MainWindow $p
    if ($hwnd -ne [IntPtr]::Zero) {
        [PTrayNative]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        Write-Log "asked pid $procId to close"
    } else {
        # No window: there is nothing to ask. TerminateProcess is the only option.
        Write-Log "pid $procId has no window - terminating it"
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    }

    $deadline = (Get-Date).AddSeconds($graceSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        if (-not (Test-PlayniteExists $procId)) { Write-Log 'Playnite exited'; return $true }
    }

    Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Test-PlayniteExists $procId)) { Write-Log 'Playnite force-stopped'; return $true }

    # A process that survives TerminateProcess is wedged inside its own exit (Windows
    # considers it terminated already). Nothing in user mode can clear it.
    Write-Log "pid $procId cannot be terminated - it is stuck in shutdown, a reboot is required"
    return $false
}

function Show-Playnite {
    # The user asked for it explicitly: stop any boot-time hiding.
    $script:bootWatch = $false
    [PTrayWatch]::WatchPid = [uint32]0

    $p = Get-PlayniteProcess
    if (-not $p) { return (Start-Playnite) }

    $hwnd = Get-MainWindow $p
    if ($hwnd -eq [IntPtr]::Zero) {
        # No window: either it is still starting (give it a moment) or it is wedged,
        # in which case showing is impossible and it has to be cycled.
        Start-Sleep -Milliseconds 1000
        $hwnd = Get-MainWindow $p
        if ($hwnd -eq [IntPtr]::Zero) {
            Write-Log 'show requested on a windowless instance - cycling it'
            if (Stop-Playnite 6) { return (Start-Playnite) }
            Show-Balloon 'Playnite could not be stopped' 'The process is stuck in shutdown and blocks new launches. Restart Windows to clear it.'
            return $false
        }
    }

    # Back to normal priority before it becomes visible, so Windows stops trimming it.
    Trim-Playnite 5

    # SW_RESTORE also un-hides a window hidden with SW_HIDE
    [PTrayNative]::ShowWindow($hwnd, 9) | Out-Null
    [PTrayNative]::SetForegroundWindow($hwnd) | Out-Null
    $script:hidden = $false
    $script:stale = $false
    $script:noWindowSince = $null
    Write-Log 'restored window'
    return $true
}

function Restart-Playnite {
    Write-Log 'restart requested'
    if (Stop-Playnite 6) {
        Start-Sleep -Milliseconds 500
        Start-Playnite | Out-Null
        return $true
    }
    Show-Balloon 'Playnite could not be stopped' 'The process is stuck in shutdown and blocks new launches. Restart Windows to clear it.'
    return $false
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
    if (-not $p) {
        $script:hidden = $false
        $script:stale = $false
        $script:noWindowSince = $null
        return
    }

    $hwnd = Get-MainWindow $p
    if ($hwnd -eq [IntPtr]::Zero) {
        # No top-level window at all. While Playnite is starting that is normal; any
        # other time it means the process is wedged and holds the single-instance lock.
        if (-not $script:noWindowSince) { $script:noWindowSince = Get-Date }
        if (-not $script:bootWatch -and -not $script:stale) {
            $age = ((Get-Date) - $script:noWindowSince).TotalSeconds
            if ($age -gt 20) {
                $script:stale = $true
                $script:hidden = $false
                Write-Log "Playnite has had no window for $([math]::Round($age)) s - treating it as stuck"
                Show-Balloon 'Playnite is stuck' 'It has no window but still blocks new launches. Use "Restart Playnite" in the tray menu; if that fails, restart Windows.'
            }
        }
        return
    }

    $script:noWindowSince = $null
    if ($script:stale) {
        $script:stale = $false
        Write-Log 'Playnite has a window again'
    }

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

$script:hidden = $false
$script:hiddenSince = $null
$script:graceUntil = (Get-Date).AddSeconds(-1)
$script:pendingTrimAt = $null
$script:watchPid = 0
$script:bootWatch = $false
$script:bootWatchUntil = (Get-Date).AddSeconds(90)
$script:stale = $false
$script:noWindowSince = $null
$script:notify = $null

# ---- action mode (no tray icon, no timers) ----
if ($Action -ne 'run') {
    $p = Get-PlayniteProcess
    switch ($Action) {
        'status' {
            if (-not $p) { 'not running'; exit 0 }
            $h = Get-MainWindow $p
            if ($h -eq [IntPtr]::Zero) {
                "running (pid $($p.Id)), no window - starting or stuck"; exit 0
            }
            "running (pid $($p.Id)), window $h, visible=$([PTrayNative]::IsWindowVisible($h)), minimized=$([PTrayNative]::IsIconic($h))"
            exit 0
        }
        'show' {
            if (Show-Playnite) { 'done'; exit 0 }
            'Playnite is stuck in shutdown; a reboot is required'; exit 1
        }
        'quit' {
            if (Stop-Playnite 6) { 'Playnite stopped'; exit 0 }
            'Playnite is stuck in shutdown; a reboot is required'; exit 1
        }
        'restart' {
            if (Restart-Playnite) { 'Playnite restarted'; exit 0 }
            'Playnite is stuck in shutdown; a reboot is required'; exit 1
        }
    }
}

# ---- one instance only ----
$mutex = New-Object System.Threading.Mutex($false, 'Global\PlayniteTrayHelper')
if (-not $mutex.WaitOne(0)) { return }
$script:mutex = $mutex

# ---- UI ----
$notify = New-Object System.Windows.Forms.NotifyIcon
try {
    $notify.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($fullscreenExe)
} catch {
    $notify.Icon = [System.Drawing.SystemIcons]::Application
}
$notify.Text = 'Playnite'
$notify.Visible = $true
$script:notify = $notify

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$itemShow = $menu.Items.Add('Show Playnite')
$itemShow.Font = New-Object System.Drawing.Font($itemShow.Font, [System.Drawing.FontStyle]::Bold)
$itemRestart = $menu.Items.Add('Restart Playnite')
$itemQuit = $menu.Items.Add('Quit Playnite')
$menu.Items.Add('-') | Out-Null
$itemExit = $menu.Items.Add('Exit tray helper')

$itemShow.add_Click({ Show-Playnite })
$itemRestart.add_Click({ Restart-Playnite | Out-Null })
$itemQuit.add_Click({
    Write-Log 'quit requested'
    if (-not (Stop-Playnite 6)) {
        Show-Balloon 'Playnite could not be stopped' 'The process is stuck in shutdown and blocks new launches. Restart Windows to clear it.'
    }
})
$itemExit.add_Click({
    $notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

$menu.add_Opening({
    $p = Get-PlayniteProcess
    if ($script:stale) {
        $itemShow.Text = 'Playnite is stuck'
        $itemShow.Enabled = $false
        $itemRestart.Text = 'Restart Playnite'
        $notify.Text = 'Playnite (stuck)'
    } else {
        $itemShow.Text = if ($p) { 'Show Playnite' } else { 'Start Playnite' }
        $itemShow.Enabled = $true
        $notify.Text = 'Playnite'
    }
    $itemRestart.Enabled = [bool]$p
    $itemQuit.Enabled = [bool]$p
})

$notify.add_MouseDoubleClick({ Show-Playnite })
$notify.ContextMenuStrip = $menu

# Session ending (shutdown / restart / logoff): close Playnite now instead of leaving it
# to Windows' shutdown timeout. A Playnite that is mid-exit when the machine suspends
# comes back as an unkillable process that blocks every future launch.
[Microsoft.Win32.SystemEvents]::add_SessionEnding({
    try {
        $p = Get-PlayniteProcess
        if (-not $p) { return }
        Write-Log 'session ending - closing Playnite'
        $h = Get-MainWindow $p
        if ($h -ne [IntPtr]::Zero) {
            [PTrayNative]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        }
        $procId = $p.Id
        $deadline = (Get-Date).AddSeconds(3)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 200
            if (-not (Test-PlayniteExists $procId)) { break }
        }
        if (-not (Test-PlayniteExists $procId)) {
            Write-Log 'session ending - Playnite closed cleanly'
        } else {
            Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
            Write-Log 'session ending - Playnite force-stopped'
        }
    } catch { }
})

# Only treat an instance that just started (or is about to start) as the boot one.
# A helper restarted mid-session must not hide a window you are using.
$existing = Get-PlayniteProcess
$script:bootWatch = $true
$startAfterRecovery = $false
if ($existing) {
    $age = ((Get-Date) - $existing.StartTime).TotalSeconds
    $hwnd = Get-MainWindow $existing

    if ($hwnd -eq [IntPtr]::Zero) {
        if ($age -lt 30) {
            Write-Log 'Playnite is still starting - watching it'
        } else {
            # Windowless and long-running: wedged instance (holds the single-instance
            # lock, so Playnite cannot start). Clear it and start a fresh one.
            Write-Log "found a windowless Playnite (age $([math]::Round($age)) s) - trying to clear it"
            $script:bootWatch = $false
            if (Stop-Playnite 4) {
                Write-Log 'cleared the stuck instance, starting Playnite'
                $startAfterRecovery = $true
                $script:bootWatch = $true
                $script:bootWatchUntil = (Get-Date).AddSeconds(90)
            } else {
                $script:stale = $true
                Show-Balloon 'Playnite is stuck' 'It has no window but still blocks new launches. Restart Windows to clear it.'
            }
        }
    } else {
        $script:bootWatch = $false
        if ([PTrayNative]::IsWindowVisible($hwnd)) {
            Write-Log 'adopted a visible instance'
        } else {
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
} elseif ($script:stale) {
    Write-Log 'boot watch: not needed (Playnite is stuck - see above)'
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

if ($startAfterRecovery) { Start-Playnite | Out-Null }

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
