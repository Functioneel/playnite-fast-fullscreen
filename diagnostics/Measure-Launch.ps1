# Measure-Launch.ps1
# Launches Playnite fullscreen, waits for first render, prints phase timings, closes cleanly.
# Also reports whether the custom theme actually loaded (a theme XAML failure silently
# falls back to the default theme and looks "fast", which invalidates timings).
# Usage: powershell -ExecutionPolicy Bypass -File .\Measure-Launch.ps1 [-Label "test"]

param([string]$Label = "")

if (Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue) {
    Write-Error 'Playnite is already running. Close it first - this script starts and stops its own instance.'
    return
}

$log = Join-Path $env:APPDATA 'Playnite\playnite.log'
$exe = Join-Path $env:LOCALAPPDATA 'Playnite\Playnite.FullscreenApp.exe'

$before = (Get-Content $log).Count
$p = Start-Process -FilePath $exe -ArgumentList '--hidesplashscreen' -PassThru
$t0 = $p.StartTime

$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
    $new = Get-Content $log | Select-Object -Skip $before
    if ($new -match 'Render screen') { break }
}

$new = Get-Content $log | Select-Object -Skip $before
if ($Label) { Write-Host "=== $Label ===" }
$prev = 0.0
foreach ($l in $new) {
    if ($l -match 'Application started from|Show window|Render screen') {
        $ts = [datetime]::ParseExact($l.Substring(0, 18), 'dd-MM HH:mm:ss.fff', $null)
        $s = ($ts - $t0).TotalSeconds
        $phase = if ($l -match 'Application started') { 'init ' } elseif ($l -match 'Show window') { 'window' } else { 'render' }
        "{0} {1,6:N2}s  (+{2:N2}s)" -f $phase, $s, ($s - $prev)
        $prev = $s
    }
}

if ($new -match 'Failed to load theme') {
    Write-Host 'THEME FAILED TO LOAD - fell back to default theme, timings invalid' -ForegroundColor Red
} elseif ($new -match 'Failed to load xaml') {
    Write-Host 'THEME XAML ERROR - timings invalid' -ForegroundColor Red
} else {
    Write-Host 'theme loaded OK'
}

$p.CloseMainWindow() | Out-Null
Start-Sleep -Seconds 3
if (Get-Process -Id $p.Id -ErrorAction SilentlyContinue) { Stop-Process -Id $p.Id -Force; Write-Host 'force-closed' } else { Write-Host 'closed cleanly' }
