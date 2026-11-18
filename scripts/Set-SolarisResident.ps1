# Set-SolarisResident.ps1
# Option C: keep Playnite resident so a "launch" is an instant Focus (measured ~0.4 s)
# instead of a 9 s Solaris cold start.
#
# Playnite's fullscreen main menu always shows an "Exit Playnite" button and the theme
# cannot rebind its command (it's a compiled part: PART_ButtonExitPlaynite). So this
# hides that button, leaving the native "Minimize" entry (MainMenuShowMinimize=true).
# Re-launching the Playnite shortcut then restores the existing window instantly.
#
# Really quitting: Alt+F4, or Task Manager, or the Powershell one-liner printed below.
# Revert: powershell -ExecutionPolicy Bypass -File .\Set-SolarisResident.ps1 -Restore

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

$menu = Join-Path $ThemeDir 'Views\MainMenu.xaml'
if (-not (Test-Path -LiteralPath $menu)) { Write-Error "MainMenu.xaml not found: $menu"; return }

$backupDir = Join-Path $env:APPDATA 'Playnite\_solaris_trim_backup'
$backup = Join-Path $backupDir 'MainMenu.xaml'
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

if ($Restore) {
    if (Test-Path -LiteralPath $backup) {
        Copy-Item -LiteralPath $backup -Destination $menu -Force
        Write-Host "Restored original MainMenu.xaml from $backup"
    } else {
        Write-Error "No backup found at $backup"
    }
    return
}

$text = [System.IO.File]::ReadAllText($menu)
if ($text -match 'Option C: keep Playnite resident') {
    Write-Host 'MainMenu.xaml already patched - nothing to do.'
    return
}

if (-not (Test-Path -LiteralPath $backup)) {
    Copy-Item -LiteralPath $menu -Destination $backup
    Write-Host "Backup written: $backup"
}

$pattern = '(?s)(?<indent>[ \t]*)<Trigger Property="Name" Value="PART_ButtonExitPlaynite">.*?</Trigger>'
$m = [regex]::Match($text, $pattern)
if (-not $m.Success) {
    Write-Warning 'Anchor trigger not found - theme layout may have changed. No changes made.'
    return
}

$ind = $m.Groups['indent'].Value
$addition = $m.Value + "`r`n`r`n" +
    "$ind<!-- Option C: keep Playnite resident - Exit hidden, use Minimize instead -->`r`n" +
    "$ind<Trigger Property=`"Name`" Value=`"PART_ButtonExitPlaynite`">`r`n" +
    "$ind    <Setter Property=`"Visibility`" Value=`"Collapsed`" />`r`n" +
    "$ind</Trigger>"

$text = $text.Substring(0, $m.Index) + $addition + $text.Substring($m.Index + $m.Length)
[System.IO.File]::WriteAllText($menu, $text, (New-Object System.Text.UTF8Encoding($false)))

Write-Host 'Exit button hidden in the fullscreen main menu.'
Write-Host 'Playnite now stays resident when you "close" it; relaunching restores it in ~0.4 s.'
Write-Host 'To really quit: Alt+F4, or run:'
Write-Host '  (Get-Process Playnite.FullscreenApp -ErrorAction SilentlyContinue).CloseMainWindow()'
Write-Host "Original kept at: $backup"
Write-Host 'Revert with: Set-SolarisResident.ps1 -Restore'
