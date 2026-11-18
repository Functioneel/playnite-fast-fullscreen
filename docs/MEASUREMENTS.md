# Measurements

All numbers from one machine, so treat them as **relative** evidence rather than benchmarks you should
expect byte-for-byte:

- Playnite 10.64, fullscreen, Solaris theme
- 1920×1080, RTX 3060, 16 GB RAM, Lexar NVMe, Windows Defender active
- Timings parsed from `%APPDATA%\Playnite\playnite.log` phase markers:
  - `Application started from` → WPF up, theme resources loaded
  - `WindowFactory:Show window` → window created
  - `Render screen` → first frame

Each run is a cold start via `Playnite.FullscreenApp.exe --hidesplashscreen`, closed with
`CloseMainWindow()` afterwards.

> **Method warning.** Any run where the theme failed to load is discarded. Playnite silently falls back
> to its default theme on a XAML error, which "improves" the timings by 3×. `Measure-Launch.ps1` now
> prints `THEME FAILED TO LOAD` so this can't be missed.

## Baseline

| Theme | init | window | render |
|---|---|---|---|
| Solaris (worst run) | 7.40 s | 9.99 s | 11.40 s |
| Solaris (typical) | 6.70–6.90 s | 8.77–9.11 s | 9.16–9.49 s |
| Playnite default theme | 1.08 s | 3.13 s | 3.45 s |

The default theme is the practical floor for any launch change: ~3.45 s. Solaris adds ~6 s of XAML
object construction on top.

## Where the Solaris cost is

Per-file bisection, by removing/restoring merges inside `Views/Main.xaml`:

| Component | Cost |
|---|---|
| `Views/Main.xaml` itself | ~1.5 s |
| `Views/Additional/*` | ~1.05 s |
| `Media.xaml` | ~0.97 s |
| `Views/MainMenu.xaml` | ~0.48 s |
| `Views/SettingsMenus.xaml` | ~0.37 s |
| `GameDetails.xaml` | ~0.4 s |
| 7 unused addon view dictionaries | ~0.43 s |
| Image decode (tested by swapping all images for 8×8 PNGs) | ~0.9 s |

No single hotspot — it is spread across theme files, which is why a rewrite would be the only way to
remove the rest. Trimming the unused addon views is the one change with no visual trade-off.

## After trimming unused addon views

| Run | init | window | render |
|---|---|---|---|
| 1 | 6.79 s | 8.90 s | 9.28 s |
| 2 | 6.70 s | 9.11 s | 9.49 s |

Theme loaded and rendered correctly; verified by screenshot.

## DXVK A/B (no gain, feature removed)

DXVK 2.x `d3d9.dll` dropped into the Playnite folder, then renamed away:

| d3d9.dll | Run 1 | Run 2 |
|---|---|---|
| DXVK 2.x | 10.35 s | 9.20 s |
| Windows system | 9.38 s | 9.16 s |

Within noise. The cost is WPF object construction, not the D3D9 path.

## Resident / restore

| Action | Time | Evidence |
|---|---|---|
| Cold start, fullscreen | ~9.2 s | log phases |
| Second launch while first is running | **0.4 s** | `Application already running, shutting down` + `Executing command "Focus"` |
| Restore from hidden (after trim) | **61 ms** to visible | `ShowWindow` + visibility poll |
| UI pump answers after restore | 10 ms | `SendMessageTimeout(WM_NULL)` |
| Boot → fullscreen via Playnite's own boot stub | 10.21 s / 10.25 s | `Test-BootToFullscreen.ps1` |
| Boot → fullscreen via direct shortcut | ~9.2 s | same script, direct exe |

## Memory

Playnite while idle in fullscreen, before trimming: **408 MB** working set, 344 MB private.

| State | Playnite WS | Playnite commit | Helper WS |
|---|---|---|---|
| Visible, idle | 408 MB | 344 MB | 95 MB |
| Hidden (no trim) | 392 MB | 305 MB | 105 MB |
| Hidden + `EmptyWorkingSet` + low priority | **17–27 MB** | 303 MB | 28 MB |
| + 30 s re-trim | 35 MB | 291 MB | 36 MB |
| Restored, 4 s later | 105–115 MB | 304 MB | — |

Physical RAM free moved 8287 MB → 8397 MB (+110 MB) across the trim. Working set collapses; **commit
does not**, because the process is still alive. That distinction is the whole story: Task Manager will
show ~25 MB, but you only actually free ~110 MB of physical memory.

Trimming the helper itself: 105 MB → 13 MB immediately, back to ~30 MB while it keeps polling.

## Post-trim rendering check

`PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT)` was captured after a full trim and restore: the
Solaris theme, background artwork, game covers and metadata all rendered identically. This matters
because a screen capture would have picked up an always-on-top Rainmeter overlay instead of Playnite.
