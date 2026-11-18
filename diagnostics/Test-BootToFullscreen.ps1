# Test-BootToFullscreen.ps1
# Simulates what happens at Windows login: starts the desktop app exactly like the
# Startup shortcut does, then measures time until a fullscreen view renders.
param([switch]$SetStartInFullscreen)

if (Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue) {
    Write-Error 'Playnite is already running. Close it first - this script starts and stops its own instance.'
    return
}

$cfgPath = Join-Path $env:APPDATA 'Playnite\config.json'
if ($SetStartInFullscreen) {
    $c = Get-Content $cfgPath -Raw
    if ($c -match '"StartInFullscreen":\s*false') {
        $c = $c -replace '"StartInFullscreen":\s*false', '"StartInFullscreen": true'
        [System.IO.File]::WriteAllText($cfgPath, $c)
        Write-Host 'StartInFullscreen set to true'
    } else {
        Write-Host 'StartInFullscreen already true (or no match)'
    }
}

$log = Join-Path $env:APPDATA 'Playnite\playnite.log'
$desktop = Join-Path $env:LOCALAPPDATA 'Playnite\Playnite.DesktopApp.exe'

$before = (Get-Content $log).Count
$p = Start-Process -FilePath $desktop -ArgumentList '--hidesplashscreen' -PassThru
$t0 = $p.StartTime

$deadline = (Get-Date).AddSeconds(90)
$hit = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
    $new = Get-Content $log | Select-Object -Skip $before
    $hit = $new | Where-Object { $_ -match 'MainViewModelBase:Render screen' } | Select-Object -First 1
    if ($hit) { break }
}

if ($hit) {
    $ts = [datetime]::ParseExact($hit.Substring(0, 18), 'dd-MM HH:mm:ss.fff', $null)
    'boot-to-fullscreen-render: {0:N2}s' -f ($ts - $t0).TotalSeconds
} else {
    'no render detected'
}

Start-Sleep -Seconds 2
Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue | Select-Object Name, Id | Format-Table -AutoSize
Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() | Out-Null }
Start-Sleep -Seconds 4
Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force; "force-closed $($_.Name)" }
