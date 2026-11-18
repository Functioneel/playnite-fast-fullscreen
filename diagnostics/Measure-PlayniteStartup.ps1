# Measure-PlayniteStartup.ps1
# Parses Playnite's log and reports real startup timings per launch.
# Usage:  powershell -ExecutionPolicy Bypass -File .\Measure-PlayniteStartup.ps1 [-Last 10]
param([int]$Last = 10)

$logPath = Join-Path $env:APPDATA 'Playnite\playnite.log'
if (-not (Test-Path $logPath)) { Write-Error "Log not found: $logPath"; return }

$themePath = Join-Path $env:APPDATA 'Playnite\fullscreenConfig.json'
$theme = if (Test-Path $themePath) { (Get-Content $themePath -Raw | ConvertFrom-Json).Theme } else { '?' }

Write-Host "Playnite log: $logPath"
Write-Host "Active fullscreen theme: $theme`n"

function Parse-Ts([string]$line) {
    try { [datetime]::ParseExact($line.Substring(0, 18), 'dd-MM HH:mm:ss.fff', $null) } catch { $null }
}

$lines = Get-Content $logPath
$results = @()

for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match 'ProcessStarter:Starting process: .*Playnite\.(Fullscreen|Desktop)App') {
        $app = $Matches[1]
        $t0 = Parse-Ts $lines[$i]
        if (-not $t0) { continue }

        $tInit = $null; $tWindow = $null; $tRender = $null
        for ($j = $i + 1; $j -lt [Math]::Min($i + 120, $lines.Count); $j++) {
            $l = $lines[$j]
            if (-not $tInit -and $l -match 'Application started from') { $tInit = Parse-Ts $l }
            if (-not $tWindow -and $l -match 'WindowFactory:Show window') { $tWindow = Parse-Ts $l }
            if (-not $tRender -and $l -match 'Render screen') { $tRender = Parse-Ts $l; break }
            if ($l -match 'ProcessStarter:Starting process') { break }
        }

        if ($tInit) {
            $results += [PSCustomObject]@{
                Started      = $t0.ToString('MM-dd HH:mm:ss')
                App          = $app
                'WPF_init_s' = [math]::Round(($tInit - $t0).TotalSeconds, 2)
                'Window_s'   = if ($tWindow) { [math]::Round(($tWindow - $t0).TotalSeconds, 2) } else { $null }
                'Rendered_s' = if ($tRender) { [math]::Round(($tRender - $t0).TotalSeconds, 2) } else { $null }
            }
        }
    }
}

if ($results.Count -eq 0) { Write-Host 'No launches found in log.'; return }
Write-Host "Last $Last launches (WPF_init = environment+theme resource load):"
$results | Select-Object -Last $Last | Format-Table -AutoSize
