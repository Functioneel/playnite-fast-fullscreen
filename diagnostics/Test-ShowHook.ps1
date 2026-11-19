# Test-ShowHook.ps1
# Diagnostic: record every EVENT_OBJECT_SHOW WinEvent for Playnite's process while it
# starts, so we can see which window actually generates the "shown" event and what its
# class / owner / visibility state is at delivery time.
#
# The helper filters on unowned + visible + class "HwndWrapper[...]". If the real event
# fails one of those, the hook silently does nothing and the timer fallback runs late.
param([int]$Seconds = 16)

Add-Type @"
using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public class HookDiag {
    public delegate void WinEventProc(IntPtr hHook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint evMin, uint evMax, IntPtr hmod, WinEventProc cb, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG msg, IntPtr hwnd, uint min, uint max);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG msg);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG msg);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct MSG {
        public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam;
        public uint time; public POINT pt;
    }

    static WinEventProc callback;
    static IntPtr hook = IntPtr.Zero;
    public static volatile uint WatchPid;
    public static readonly ConcurrentQueue<string> Events = new ConcurrentQueue<string>();

    public static bool Start() {
        var t = new Thread(Loop) { IsBackground = true, Name = "HookDiag" };
        t.Start();
        for (int i = 0; i < 100 && hook == IntPtr.Zero; i++) Thread.Sleep(10);
        return hook != IntPtr.Zero;
    }

    static void Loop() {
        callback = OnShow;
        hook = SetWinEventHook(0x8002, 0x8002, IntPtr.Zero, callback, 0, 0, 0x0002);
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
        var cls = new StringBuilder(256); GetClassName(hwnd, cls, 256);
        var txt = new StringBuilder(256); GetWindowText(hwnd, txt, 256);
        RECT r; GetWindowRect(hwnd, out r);
        Events.Enqueue(string.Format("idObj={0} idChild={1} owner={2} visible={3} rect={4}x{5} class='{6}' title='{7}'",
            idObject, idChild, GetWindow(hwnd, 4), IsWindowVisible(hwnd),
            r.R - r.L, r.B - r.T, cls, txt));
    }
}
"@

if (Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue) { Write-Error 'Close Playnite first.'; return }

$exe = Join-Path $env:LOCALAPPDATA 'Playnite\Playnite.FullscreenApp.exe'
if (-not [HookDiag]::Start()) { Write-Error 'hook installation failed'; return }
"hook installed"
[HookDiag]::WatchPid = [uint32]0

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$p = Start-Process -FilePath $exe -ArgumentList '--hidesplashscreen' -PassThru
[HookDiag]::WatchPid = [uint32]$p.Id
"watching pid $($p.Id) at $([math]::Round($sw.Elapsed.TotalMilliseconds)) ms"

Start-Sleep -Seconds $Seconds

"---- events for that pid ----"
$all = New-Object System.Collections.Generic.List[string]
$item = ''
while ([HookDiag]::Events.TryDequeue([ref]$item)) { $all.Add($item) }
"count: $($all.Count)"
$all | ForEach-Object { $_ }

Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() | Out-Null }
Start-Sleep -Seconds 4
Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force }
'cleaned up'
