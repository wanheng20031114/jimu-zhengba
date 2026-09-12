param(
    [Parameter(Mandatory)][string]$Executable,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$RunId,
    [switch]$Cavalry,
    [switch]$Priests,
    [switch]$FocusFire,
    [switch]$NaturalHealth,
    [switch]$HarnessCheck,
    [ValidateRange(30, 120)][int]$SustainedSeconds = 30,
    [ValidateSet('baseline', 'no-body-sweep', 'no-avoidance', 'static-motion', 'frozen-animation', 'no-unit-draw', 'frozen-batches', 'stationary-pruning')]
    [string]$Experiment = 'baseline'
)
$ErrorActionPreference = 'Stop'
$battleExecutable = (Resolve-Path -LiteralPath $Executable).Path
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$battleOutput = (Resolve-Path -LiteralPath $OutputDirectory).Path
if (Test-Path -LiteralPath (Join-Path $battleOutput ($RunId + '.json'))) {
    throw 'Choose a fresh run ID; existing benchmark evidence will not be overwritten.'
}
$battleArguments = @('--position', '40,40', '--resolution', '1600x900', '--',
    ('--run-id=' + $RunId), ('"--output=' + $battleOutput + '"'))
if ($Cavalry) { $battleArguments += '--cavalry' }
if ($FocusFire) { $battleArguments += '--focus-fire' }
if ($Priests) {
    if ($Cavalry) { throw 'Priests requires the mixed roster.' }
    $battleArguments += '--priests'
}
if ($NaturalHealth) { $battleArguments += '--natural-health' }
if ($HarnessCheck) { $battleArguments += '--harness-check' }
if ($SustainedSeconds -ne 30) { $battleArguments += ('--sustained-seconds=' + $SustainedSeconds) }
if ($Experiment -ne 'baseline') { $battleArguments += ('--experiment=' + $Experiment) }
$battleProcess = Start-Process -FilePath $battleExecutable -ArgumentList $battleArguments -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $battleOutput ($RunId + '.stdout.log')) `
    -RedirectStandardError (Join-Path $battleOutput ($RunId + '.stderr.log'))
$battleProcess.Id | Set-Content -Encoding UTF8 (Join-Path $battleOutput ($RunId + '.pid'))
$battleObservations = @()
$battleClock = [System.Diagnostics.Stopwatch]::StartNew()
try {
    Write-Output ('Benchmark ' + $RunId + ' PID ' + $battleProcess.Id)
    while (-not $battleProcess.WaitForExit(5000)) {
        # Observe other tasks; never stop an editor or another task's tests.
        $otherGodot = @(Get-CimInstance Win32_Process | Where-Object {
            $_.ProcessId -ne $battleProcess.Id -and ($_.Name -like 'Godot*' -or $_.Name -eq 'battle-600.exe')
        })
        $otherTests = @($otherGodot | Where-Object {
            $_.ProcessId -ne $battleProcess.Id -and
            (($_.Name -like 'Godot*' -and $_.CommandLine -match '--script|--headless|--check-only|--export') -or $_.Name -eq 'battle-600.exe')
        } | Select-Object ProcessId, Name)
        $background = @($otherGodot | Select-Object ProcessId, Name, CommandLine, UserModeTime, KernelModeTime)
        $battleObservations += [pscustomobject]@{ elapsed_s=$battleClock.Elapsed.TotalSeconds; other_tests=$otherTests; background_godot=$background }
        if ($battleClock.Elapsed.TotalSeconds -gt 210) { throw 'Benchmark exceeded its external 210-second timeout.' }
    }
    $battleProcess.Refresh()
    $battleObservations | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $battleOutput ($RunId + '.environment.json'))
    Get-Content -Encoding UTF8 (Join-Path $battleOutput ($RunId + '.stdout.log')) -Tail 12
    $errors = Get-Content -Raw -Encoding UTF8 (Join-Path $battleOutput ($RunId + '.stderr.log'))
    if ($errors) { Write-Output $errors }
    if ($battleProcess.ExitCode -ne 0 -or $errors -match 'SCRIPT ERROR|ERROR:') { throw 'Benchmark failed; inspect its native logs.' }
    if (-not (Test-Path -LiteralPath (Join-Path $battleOutput ($RunId + '.json')))) { throw 'Benchmark exited without a result.' }
    $battleResult = Get-Content -Raw -Encoding UTF8 (Join-Path $battleOutput ($RunId + '.json')) | ConvertFrom-Json
    if ($Priests -and $battleResult.roster_per_owner.priest -ne 2) {
        throw 'The executable did not apply the requested priest roster.'
    }
    if ($FocusFire -and -not $battleResult.focus_fire) {
        throw 'The executable did not apply the requested explicit attack orders.'
    }
    if (-not $HarnessCheck) {
        $sustained = @($battleResult.phases | Where-Object { $_.name -eq 'sustained_overview' })
        if ($sustained.Count -ne 1 -or $sustained[0].duration_s -lt $SustainedSeconds) {
            throw 'The executable did not complete the requested sustained observation duration.'
        }
    }
    if ($Experiment -ne 'baseline' -and $battleResult.diagnostic_experiment -ne $Experiment) {
        throw 'The executable did not apply the requested experiment; use a diagnostic build.'
    }
} finally {
    if (-not $battleProcess.HasExited) {
        $owned = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $battleProcess.Id)
        if ($owned -and $owned.ExecutablePath -eq $battleExecutable) {
            Stop-Process -Id $battleProcess.Id
            $battleProcess.WaitForExit(10000) | Out-Null
        }
    }
    if (Get-Process -Id $battleProcess.Id -ErrorAction SilentlyContinue) { throw 'Owned benchmark process did not exit.' }
}
