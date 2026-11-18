# playnite-fast-fullscreen

Make Playnite's fullscreen mode start fast, live in the system tray, and reopen almost instantly.

Built for **Playnite 10.x + a heavy WPF theme (Solaris)**, where a cold start into fullscreen takes
11–13 s. After these changes: **~9.2 s once at login**, then **~0.06 s** every time you "open" it again,
and **~25 MB** of resident RAM while it sits in the tray.

Nothing here forks Playnite or replaces your theme. It is four small, reversible changes.

> Not affiliated with Playnite or the Solaris theme. Playnite is by Josef Němec.

---

## Results

Measured on Playnite 10.64 + Solaris, 1920×1080, RTX 3060, 16 GB RAM, NVMe. Your numbers will differ,
but the ratios hold.

| Scenario | Before | After |
|---|---|---|
| Cold start → first rendered frame (Solaris) | 9.9–11.4 s | 9.2–9.5 s |
| Cold start, Playnite's default theme (floor) | 3.45 s | 3.45 s |
| "Open Playnite" while resident | 9.2 s (cold) | **0.06 s** (restore) |
| Resident RAM while in the tray | ~400 MB | **~27 MB** |
| Boot to fullscreen at login | ~9.2 s | ~10.2 s (Playnite's own boot stub) |

The cold start can't go much below ~9 s: that time is Playnite instantiating the theme's XAML, not
something a script can remove. What these changes do is make you pay it **once per login** instead of
every time you launch.

---

## How it works

### 1. Theme trimming — `Trim-SolarisUnusedViews.ps1`

Solaris' `Views/Main.xaml` merges ~18 resource dictionaries, including views for plugins you don't
have installed (PlayniteAchievements, SuccessStory, CheckDLC, ScreenshotsVisualizer,
ScreenshotUtilities, NowPlaying). They are parsed on every start and deserialized eagerly.

The script comments those merges out and keeps the ones that matter (including UniPlaySong).
Saves roughly 0.4 s.

### 2. Resident mode — `Set-SolarisResident.ps1`

Playnite's fullscreen main menu always offers **"Exit Playnite"**, and a theme cannot rebind that
button's command — it is a compiled part (`PART_ButtonExitPlaynite`). Pressing it means a real process
exit, i.e. the next launch is a full cold start.

The script hides that button, leaving Playnite's native **Minimize** entry (enabled via
`MainMenuShowMinimize` in `fullscreenConfig.json`). Now "closing" means minimizing, and the process
stays alive.

To really quit: **Alt+F4**, the tray menu's *Quit Playnite*, or

```powershell
(Get-Process Playnite.FullscreenApp -ErrorAction SilentlyContinue).CloseMainWindow()
```

### 3. Tray helper — `PlayniteTray.ps1` + `PlayniteTray.vbs`

Playnite fullscreen has no tray support (only the desktop app does), and its Minimize leaves the app
on the taskbar. The helper:

- polls every 700 ms for a minimized Playnite window and hides it (`SW_HIDE`) — gone from taskbar and Alt+Tab,
- trims Playnite's working set (`EmptyWorkingSet`) and sets **low memory priority**, so a hidden
  Playnite drops from ~400 MB to ~25 MB resident,
- re-trims every 30 s while hidden, because WPF slowly faults pages back in,
- restores memory priority to normal and calls `SW_RESTORE` when you pick *Show Playnite* (double-click
  the tray icon or use the menu),
- offers *Show / Quit Playnite* and *Exit tray helper*.

`PlayniteTray.vbs` starts it through `wscript` so no console window flashes at login.

Relaunching the Playnite shortcut while it's resident also restores it in ~0.4 s: the second process
exits, sends `Focus` over Playnite's IPC pipe, and the existing window comes back.

### 4. One boot path — `Set-PlayniteBoot.ps1`

Only one thing should start Playnite at login. Two options, never both:

- **Native** (default) — uses Playnite's own *Start on boot* setting. Sets
  `StartOnBoot=true`, `StartInFullscreen=true`, `StartOnBootClosedToTray=false`, and writes
  `Startup\Playnite.lnk` pointing at `Playnite.DesktopApp.exe --hidesplashscreen`. Playnite's desktop
  process immediately relaunches the fullscreen exe and exits, costing ~1.2 s. The checkbox in
  Playnite's UI is then truthful, and Playnite leaves the shortcut alone because it already matches
  what it would write.
- **Direct** — all three settings `false`, and a `Playnite Fullscreen.lnk` that points straight at
  `Playnite.FullscreenApp.exe`. Saves the ~1.2 s handoff, but Playnite's *Start on boot* checkbox
  will read OFF.

Pick one, then stop touching it. Running both is what produces double launches and confusing settings.

---

## Requirements

- Windows 10 or 11, Windows PowerShell 5.1 (built in)
- Playnite 10.x (per-user install), fullscreen mode configured
- Solaris theme, if you want the two theme scripts; the tray/boot scripts are theme-independent
- **Pagefile enabled** — the memory trimming moves pages to the pagefile/standby list. On a system
  with the pagefile disabled, skip the trimming or accept that it does nothing useful.

No admin rights are needed for any of it (everything is under `%LOCALAPPDATA%`, `%APPDATA%` and your
own Startup folder).

---

## Install

**Close Playnite first.** Several scripts edit `config.json` or theme files, and Playnite rewrites
`config.json` on exit.

```powershell
git clone https://github.com/<you>/playnite-fast-fullscreen.git
cd playnite-fast-fullscreen
```

Then, in this order:

```powershell
# 1. Boot path (choose Native, or -Mode Direct for the faster one)
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Set-PlayniteBoot.ps1

# 2. Tray helper (installs the Startup shortcut and starts it now)
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-PlayniteTray.ps1

# 3. Theme: drop unused plugin views, then hide the Exit button
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Trim-SolarisUnusedViews.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Set-SolarisResident.ps1
```

Start Playnite once. From now on: Minimize sends it to the tray; the tray icon or the Playnite
shortcut brings it back instantly.

Both theme scripts find `Solaris*` under `%APPDATA%\Playnite\Themes\Fullscreen` automatically. If you
have more than one Solaris variant, pass `-ThemeDir "C:\...\Solaris_<id>"`.

---

## Script reference

| Script | What it changes | Revert |
|---|---|---|
| `scripts/Set-PlayniteBoot.ps1` | Playnite's three boot settings + the Startup shortcut | `-Revert` |
| `scripts/Install-PlayniteTray.ps1` | `Startup\Playnite Tray.lnk`, starts/stops the helper | `-Uninstall` |
| `scripts/Trim-SolarisUnusedViews.ps1` | comments unused addon merges in `Views/Main.xaml` | `-Restore` |
| `scripts/Set-SolarisResident.ps1` | hides `PART_ButtonExitPlaynite` in `Views/MainMenu.xaml` | `-Restore` |
| `scripts/PlayniteTray.ps1` | the resident tray helper itself | `Install-PlayniteTray.ps1 -Uninstall` |
| `scripts/PlayniteTray.vbs` | silent launcher for the helper | — |

All scripts are idempotent: running them twice is safe and prints "already patched".

### Where backups live

- `%APPDATA%\Playnite\_solaris_trim_backup\` — original `Main.xaml`, `MainMenu.xaml`
- Startup shortcuts are recreated, not deleted, on revert

---

## Reverting everything

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-PlayniteTray.ps1 -Uninstall
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Set-SolarisResident.ps1 -Restore
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Trim-SolarisUnusedViews.ps1 -Restore
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Set-PlayniteBoot.ps1 -Revert
```

Then, if you want Playnite to boot again, re-enable **Start on boot** in its settings. `-Revert` leaves
all three boot settings `false`, so nothing starts automatically until you do.

---

## Memory: what trimming does and does not do

Two different numbers get called "RAM":

| | While visible | Hidden, untrimmed | Hidden, trimmed |
|---|---|---|---|
| Working set (Task Manager "Memory") | ~408 MB | ~392 MB | **~27 MB** |
| Private commit | ~344 MB | ~305 MB | ~300 MB |
| Tray helper | 95 MB | 95 MB | ~28 MB |

The trimming pushes resident pages to the pagefile / Windows' standby list, and low memory priority
keeps them out. **Commit does not drop** — the process is still alive with its XAML objects and
decoded images. Real physical RAM freed measured around **110 MB**, not 380 MB, because part of the
working set is shared DLL and font pages you never had exclusively.

Restoring after a full trim costs **61 ms** to a visible, correctly rendered window (measured, and
verified with `PrintWindow` so an overlay can't fake the result). Pages fault back in as you scroll.

If you don't want the helper touching process memory, delete the `Trim-Playnite` calls in
`PlayniteTray.ps1`; hide/show still works.

---

## Diagnostics

Read-only or self-cleaning; none of them leave Playnite running.

| Script | Purpose |
|---|---|
| `diagnostics/Measure-Launch.ps1` | launches Playnite, prints init / window / render timings, **flags silent theme fallback** (a broken theme loads the default one and looks "fast") |
| `diagnostics/Measure-PlayniteStartup.ps1` | parses `playnite.log` and tabulates the last N launches |
| `diagnostics/Measure-Memory.ps1` | visible → hidden → trimmed → restored, with working set and commit |
| `diagnostics/Test-BootToFullscreen.ps1` | simulates the login path (desktop exe) and times it to first fullscreen render |
| `diagnostics/Test-MinimizeRestore.ps1` | proves relaunching while minimized restores instead of cold-starting |
| `diagnostics/Test-TrayTrim.ps1` | end-to-end check of hide → trim → restore with the real helper |

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\diagnostics\Measure-Launch.ps1 -Label "after changes"
```

---

## Troubleshooting

**Timings look too good (1–2 s) and the UI looks plain.** The theme failed to load and Playnite fell
back to its default. `Measure-Launch.ps1` prints `THEME FAILED TO LOAD` in that case — restore the
backup and check the XAML edit.

**After a Solaris update, the start is slow again.** Theme updates replace `Main.xaml` and
`MainMenu.xaml`. Re-run `Trim-SolarisUnusedViews.ps1` and `Set-SolarisResident.ps1`.

**"Exit Playnite" is still visible in the fullscreen menu.** That theme build uses a different part
name. Open `Views/MainMenu.xaml` and look for `PART_ButtonExitPlaynite`; if it's named differently,
pass the correct name or open an issue with the theme version.

**Two Playnite windows / double launch at login.** Both boot paths exist. Run
`Set-PlayniteBoot.ps1` (whichever mode you want) — it removes the other shortcut.

**Playnite's *Start on boot* checkbox flips itself off.** Do not run
`Set-PlayniteBoot.ps1 -Mode Direct` while you want the checkbox on; Direct deliberately disables it.
Native mode keeps it on.

**Tray icon missing after login.** Check `%TEMP%\playnite-tray.log`; start manually with
`wscript.exe scripts\PlayniteTray.vbs`. The helper refuses to run twice (named mutex).

**Screenshots of the Playnite menu look wrong/desktop-y.** If you run Rainmeter or another
always-on-top overlay, `CopyFromScreen` captures that instead. Use `PrintWindow` (as
`Measure-Memory.ps1` does) to capture the window itself.

**Execution policy errors.** All documented commands use `-ExecutionPolicy Bypass` for the single
process; nothing is changed machine-wide.

---

## Repo layout

```
scripts/       installable pieces (boot, tray helper, theme patches)
diagnostics/   measurement and verification tools
docs/          measured results in detail
```

## License

MIT — see [LICENSE](LICENSE).
