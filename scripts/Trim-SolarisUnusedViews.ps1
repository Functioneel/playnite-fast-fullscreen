# Trim-SolarisUnusedViews.ps1
# Solaris' Views/Main.xaml merges 18 resource dictionaries, including XAML views for
# plugins that aren't installed (PlayniteAchievements, SuccessStory, CheckDLC,
# ScreenshotsVisualizer, ScreenshotUtilities, NowPlaying). Those files are parsed on
# every Playnite start and cost ~0.4 s for nothing.
#
# This comments out those merge lines. Verified to load and render correctly.
# UniPlaySong's view is kept because that plugin IS installed.
#
# Re-run after a Solaris theme update (updates restore the original Main.xaml).
# Usage:  powershell -ExecutionPolicy Bypass -File .\Trim-SolarisUnusedViews.ps1 [-Restore]

param(
    [string]$ThemeDir,
    [switch]$Restore
)

if (-not $ThemeDir) {
    $base = Join-Path $env:APPDATA 'Playnite\Themes\Fullscreen'
    $cands = @(Get-ChildItem -Path $base -Directory -Filter 'Solaris*' -ErrorAction SilentlyContinue)
    if ($cands.Count -eq 0) { Write-Error "No Solaris theme found in $base - pass -ThemeDir explicitly."; return }
    if ($cands.Count -gt 1) {
        Write-Error "Multiple Solaris themes found - pass -ThemeDir. Candidates:`n$($cands.FullName -join "`n")"
        return
    }
    $ThemeDir = $cands[0].FullName
}

$main = Join-Path $ThemeDir 'Views\Main.xaml'
if (-not (Test-Path -LiteralPath $main)) { Write-Error "Main.xaml not found: $main"; return }

$backupDir = Join-Path $env:APPDATA 'Playnite\_solaris_trim_backup'
$backup = Join-Path $backupDir 'Main.xaml'
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

if ($Restore) {
    if (Test-Path -LiteralPath $backup) {
        Copy-Item -LiteralPath $backup -Destination $main -Force
        Write-Host "Restored original Main.xaml from $backup"
    } else {
        Write-Error "No backup found at $backup"
    }
    return
}

$lines = [System.IO.File]::ReadAllLines($main)
if ($lines -match "<!-- .*Views/Addons/") {
    Write-Host 'Main.xaml already trimmed - nothing to do.'
    return
}

if (-not (Test-Path -LiteralPath $backup)) {
    Copy-Item -LiteralPath $main -Destination $backup
    Write-Host "Backup written: $backup"
}

$count = 0
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match "Views/Addons/" -and $lines[$i] -notmatch "UniPlaySong") {
        $lines[$i] = "<!-- " + $lines[$i] + " -->"
        $count++
    }
}

[System.IO.File]::WriteAllLines($main, $lines, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Trimmed $count unused addon view dictionaries from Main.xaml."
Write-Host "Original kept at: $backup"
Write-Host 'Revert with: Trim-SolarisUnusedViews.ps1 -Restore'
