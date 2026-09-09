param(
    [ValidateSet('1v1', '2v2', 'both')][string]$Mode = 'both',
    [string]$GodotPath = 'C:/Program Files/Godot/Godot_console.exe',
    [switch]$HarnessCheck,
    [int]$TimeoutSeconds = 160
)
# Run after coordinating exclusive GPU access. This script never stops other apps.
$ErrorActionPreference = 'Stop'
$profileProject = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$profileArtifactDirectory = Join-Path $profileProject 'artifacts'
[IO.Directory]::CreateDirectory($profileArtifactDirectory) | Out-Null
$profileModes = if ($Mode -eq 'both') { @('1v1', '2v2') } else { @($Mode) }
$profileObserved = Get-CimInstance Win32_Process | Where-Object {
    $_.Name -match 'Godot|Endfield|Unity|Unreal|NVIDIA Overlay|chrome|msedge|ChatGPT|Codex|dwm'
} | Select-Object ProcessId, Name, CommandLine
$profileObserved | ConvertTo-Json -Depth 3 | Set-Content -Encoding utf8 (Join-Path $profileArtifactDirectory 'skirmish_profile_observed_processes.json')
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    & nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,driver_version --format=csv |
        Set-Content -Encoding utf8 (Join-Path $profileArtifactDirectory 'skirmish_profile_gpu_before.csv')
}
foreach ($profileMode in $profileModes) {
    $profileSuffix = if ($HarnessCheck) { '_harness' } else { '' }
    $profileStem = 'skirmish_stress_' + $profileMode + $profileSuffix
    $profileOutput = Join-Path $profileArtifactDirectory ($profileStem + '.log')
    $profileErrors = Join-Path $profileArtifactDirectory ($profileStem + '_error.log')
    $profileArguments = @('--path', ('"' + $profileProject + '"'), '--script', 'res://tests/skirmish_stress_test.gd')
    if ($HarnessCheck) {
        $profileArguments += '--headless'
    } else {
        $profileArguments += @('--rendering-method', 'forward_plus', '--rendering-driver', 'vulkan', '--resolution', '1600x900')
    }
    $profileArguments += '--'
    if ($profileMode -eq '2v2') { $profileArguments += '--2v2' }
    if ($HarnessCheck) { $profileArguments += '--harness-check' }
    $profileRun = $null
    $profileRelatedIds = @()
    try {
        $profileRun = Start-Process -FilePath $GodotPath -ArgumentList $profileArguments -WorkingDirectory $profileProject -WindowStyle Hidden -PassThru -RedirectStandardOutput $profileOutput -RedirectStandardError $profileErrors
        $profileWatch = [Diagnostics.Stopwatch]::StartNew()
        while (-not $profileRun.HasExited) {
            # Discover the console wrapper's native child during loading, then keep
            # WMI enumeration out of the measured frame-time window.
            if ($profileRelatedIds.Count -eq 0 -and $profileWatch.Elapsed.TotalSeconds -lt 4) {
                $profileRelatedIds += @(Get-CimInstance Win32_Process | Where-Object {
                    $_.ParentProcessId -eq $profileRun.Id -and $_.Name -like '*Godot*'
                } | Select-Object -ExpandProperty ProcessId)
            }
            if ($profileWatch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw "Benchmark timeout: $profileMode" }
            Start-Sleep -Milliseconds 250
            $profileRun.Refresh()
        }
        if ($profileRun.ExitCode -ne 0) { throw "Godot benchmark failed ($($profileRun.ExitCode)); inspect $profileErrors" }
        $profileErrorText = Get-Content -LiteralPath $profileErrors -Encoding utf8 -Raw
        if ($profileErrorText -match 'SCRIPT ERROR|SHADER ERROR|^ERROR:') { throw "Godot emitted an error; inspect $profileErrors" }
        Write-Output "Completed $profileMode. Report: $(Join-Path $profileArtifactDirectory ($profileStem + '.json'))"
    } finally {
        if ($null -ne $profileRun) {
            $profileOwnedIds = @($profileRun.Id) + @($profileRelatedIds | Sort-Object -Unique)
            $profileSurvivors = @(Get-CimInstance Win32_Process | Where-Object {
                $_.ProcessId -in $profileOwnedIds -and $_.Name -like '*Godot*'
            })
            foreach ($profileSurvivor in $profileSurvivors) { Stop-Process -Id $profileSurvivor.ProcessId -Force -ErrorAction SilentlyContinue }
            $profileRemaining = @(Get-CimInstance Win32_Process | Where-Object {
                $_.ProcessId -in $profileOwnedIds -and $_.Name -like '*Godot*'
            })
            if ($profileRemaining.Count -ne 0) { throw 'Benchmark-owned Godot processes remain after cleanup.' }
            Write-Output "Verified benchmark process cleanup: $($profileOwnedIds -join ', ')"
        }
    }
}
