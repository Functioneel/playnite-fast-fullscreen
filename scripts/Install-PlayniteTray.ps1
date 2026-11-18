# Install-PlayniteTray.ps1
# Adds a Startup shortcut that runs the Playnite tray helper silently at login.
#
# Usage:  powershell -ExecutionPolicy Bypass -File .\Install-PlayniteTray.ps1
# Remove: powershell -ExecutionPolicy Bypass -File .\Install-PlayniteTray.ps1 -Uninstall

param([switch]$Uninstall)

$dir = Split-Path $PSCommandPath
$vbs = Join-Path $dir 'PlayniteTray.vbs'
$shortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Playnite Tray.lnk'

if ($Uninstall) {
    if (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut -Force; Write-Host 'Startup shortcut removed.' }
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*-File*PlayniteTray.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host "Stopped helper PID $($_.ProcessId)" }
    Write-Host 'Tray helper uninstalled.'
    return
}

if (-not (Test-Path -LiteralPath $vbs)) { Write-Error "Missing $vbs"; return }

$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut($shortcut)
$lnk.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$lnk.Arguments = '"' + $vbs + '"'
$lnk.WorkingDirectory = $dir
$lnk.Description = 'Playnite tray helper'
$lnk.Save()

Write-Host "Installed: $shortcut"
Write-Host "Starts: wscript.exe `"$vbs`""

# Start it now so you don't have to log out
$already = Get-CimInstance Win32_Process -Filter "Name = 'wscript.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*PlayniteTray.vbs*' } | Select-Object -First 1
if ($already) {
    Write-Host "Helper already running (wscript PID $($already.ProcessId))."
} else {
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + $vbs + '"')
    Start-Sleep -Seconds 2
}
$running = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*-File*PlayniteTray.ps1*' }
if ($running) { Write-Host "Tray helper is running (PID $($running[0].ProcessId))." } else { Write-Host 'WARNING: helper did not start - check %TEMP%\playnite-tray.log' }
