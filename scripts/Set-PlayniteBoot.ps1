# Set-PlayniteBoot.ps1
# Configures the single boot-to-Playnite-fullscreen path. Two modes, never both.
#
#   Native (default) - uses Playnite's own "Start on boot" switch.
#       StartOnBoot=true, StartInFullscreen=true, StartOnBootClosedToTray=false.
#       Playnite writes Startup\Playnite.lnk -> Playnite.DesktopApp.exe --hidesplashscreen.
#       The desktop process immediately relaunches Playnite.FullscreenApp.exe with the
#       same args and exits (PlayniteApplication.cs), costing ~1.2 s extra at login.
#       Use this if you want the "Start on boot" checkbox in Playnite's UI to be honest.
#
#   Direct - bypasses Playnite's switch for a faster boot.
#       All three settings false; we own Startup\Playnite Fullscreen.lnk pointing
#       straight at Playnite.FullscreenApp.exe. Saves ~1.2 s, but Playnite's
#       "Start on boot" checkbox will read OFF.
#
# Revert (removes both boot shortcuts, all three settings false):
#   powershell -ExecutionPolicy Bypass -File .\Set-PlayniteBoot.ps1 -Revert

param(
    [ValidateSet('Native', 'Direct')]
    [string]$Mode = 'Native',
    [switch]$Revert
)

$cfgPath      = Join-Path $env:APPDATA 'Playnite\config.json'
$startupDir   = [Environment]::GetFolderPath('Startup')
$managedLnk   = Join-Path $startupDir 'Playnite.lnk'
$directLnk    = Join-Path $startupDir 'Playnite Fullscreen.lnk'
$desktopExe   = Join-Path $env:LOCALAPPDATA 'Playnite\Playnite.DesktopApp.exe'
$fullscrExe   = Join-Path $env:LOCALAPPDATA 'Playnite\Playnite.FullscreenApp.exe'
$installDir   = Join-Path $env:LOCALAPPDATA 'Playnite'
$ws = New-Object -ComObject WScript.Shell

if (-not (Test-Path -LiteralPath $cfgPath)) { Write-Error "config.json not found: $cfgPath"; return }

# Playnite rewrites config.json on exit, so it must not be running.
if (Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue) {
    Write-Error 'Close Playnite first - it rewrites config.json on exit.'
    return
}

function Set-Flags([bool]$onBoot, [bool]$closedToTray, [bool]$inFullscreen) {
    $c = Get-Content $cfgPath -Raw
    $c = $c -replace '"StartOnBoot":\s*(true|false)',           "`"StartOnBoot`": $($onBoot.ToString().ToLower())"
    $c = $c -replace '"StartOnBootClosedToTray":\s*(true|false)', "`"StartOnBootClosedToTray`": $($closedToTray.ToString().ToLower())"
    $c = $c -replace '"StartInFullscreen":\s*(true|false)',       "`"StartInFullscreen`": $($inFullscreen.ToString().ToLower())"
    [System.IO.File]::WriteAllText($cfgPath, $c, (New-Object System.Text.UTF8Encoding($false)))
}

function Show-State {
    $c = Get-Content $cfgPath -Raw | ConvertFrom-Json
    Write-Host ''
    Write-Host "Settings: StartOnBoot=$($c.StartOnBoot)  StartOnBootClosedToTray=$($c.StartOnBootClosedToTray)  StartInFullscreen=$($c.StartInFullscreen)"
    Write-Host 'Startup shortcuts:'
    Get-ChildItem $startupDir -Filter 'Playnite*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
        $l = $ws.CreateShortcut($_.FullName)
        Write-Host "  $($_.Name)  ->  $($l.TargetPath) $($l.Arguments)"
    }
}

if ($Revert) {
    Set-Flags $false $false $false
    foreach ($p in @($managedLnk, $directLnk)) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    Write-Host 'Reverted: both boot shortcuts removed, all boot settings false.'
    Show-State
    return
}

if ($Mode -eq 'Direct') {
    Set-Flags $false $false $false
    if (Test-Path -LiteralPath $managedLnk) { Remove-Item -LiteralPath $managedLnk -Force }

    $lnk = $ws.CreateShortcut($directLnk)
    $lnk.TargetPath = $fullscrExe
    $lnk.Arguments = '--hidesplashscreen'
    $lnk.WorkingDirectory = $installDir
    $lnk.Description = 'Playnite fullscreen'
    $lnk.Save()

    Write-Host 'Mode: Direct - boots straight into the fullscreen exe (~1.2 s faster).'
    Write-Host 'Playnite''s "Start on boot" checkbox will show OFF (settings are managed by this script).'
    Show-State
    return
}

# Native
Set-Flags $true $false $true
if (Test-Path -LiteralPath $directLnk) { Remove-Item -LiteralPath $directLnk -Force }

# Write exactly what Playnite's SetBootupStateRegistration would write, so Playnite
# finds it already correct and leaves it alone on exit.
$lnk = $ws.CreateShortcut($managedLnk)
$lnk.TargetPath = $desktopExe
$lnk.Arguments = '--hidesplashscreen'
$lnk.WorkingDirectory = $installDir
$lnk.Save()

Write-Host 'Mode: Native - Playnite owns the boot shortcut.'
Write-Host 'At login the desktop exe relaunches the fullscreen app and exits (~1.2 s handoff).'
Show-State
