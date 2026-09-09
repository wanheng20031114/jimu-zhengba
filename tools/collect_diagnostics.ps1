[CmdletBinding()]
param(
    [string]$GameDirectory = $PSScriptRoot,
    [string]$OutputDirectory = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'AshenCrown-Diagnostics')
)

# Local, read-only diagnosis. This script never uploads files or changes settings.
# It copies only this game's logs; crash memory dumps are listed, never copied.
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$gameRoot = (Resolve-Path -LiteralPath $GameDirectory).Path
if (-not (Test-Path -LiteralPath $gameRoot -PathType Container)) {
    throw 'GameDirectory must be the folder containing AshenCrown.exe.'
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff')
$sessionName = 'AshenCrown-' + $stamp + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$sessionRoot = Join-Path $outputRoot $sessionName
[IO.Directory]::CreateDirectory($sessionRoot) | Out-Null
$issues = [Collections.Generic.List[string]]::new()

function Write-JsonFile {
    param([string]$Name, [object]$Value)
    $text = ConvertTo-Json -InputObject $Value -Depth 8
    [IO.File]::WriteAllText((Join-Path $sessionRoot $Name), $text, [Text.UTF8Encoding]::new($false))
}

function Test-GameExecutableName {
    param([string]$Value)
    return $Value.Trim().Trim('"') -match '(?:^|[\\/])(?:AshenCrown|Godot(?:[_-][^\\/]*)?)\.exe$'
}

# Package metadata and hashes let a report be matched to the exact installed build.
$packageFiles = @()
foreach ($fileName in @('AshenCrown.exe', 'AshenCrown.pck')) {
    $filePath = Join-Path $gameRoot $fileName
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        $issues.Add('Package file missing: ' + $fileName)
        continue
    }
    try {
        $file = Get-Item -LiteralPath $filePath
        $details = [ordered]@{
            name = $file.Name
            bytes = $file.Length
            last_write_utc = $file.LastWriteTimeUtc.ToString('o')
            sha256 = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        if ($file.Extension -eq '.exe') {
            $details.file_version = $file.VersionInfo.FileVersion
            $details.product_version = $file.VersionInfo.ProductVersion
        }
        $packageFiles += [PSCustomObject]$details
    } catch {
        $issues.Add('Could not inspect ' + $fileName + ': ' + $_.Exception.Message)
    }
}
Write-JsonFile 'package.json' @{
    captured_utc = (Get-Date).ToUniversalTime().ToString('o')
    files = @($packageFiles)
}

# Query hardware information without serial numbers, account names, or unrelated
# process command lines. GPU driver version and current free RAM help diagnose
# renderer initialization failures and memory pressure.
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $cpu = @(Get-CimInstance -ClassName Win32_Processor | ForEach-Object {
        [PSCustomObject]@{ name = $_.Name; cores = $_.NumberOfCores; logical_processors = $_.NumberOfLogicalProcessors }
    })
    $gpu = @(Get-CimInstance -ClassName Win32_VideoController | ForEach-Object {
        [PSCustomObject]@{
            name = $_.Name
            driver_version = $_.DriverVersion
            driver_date = if ($null -ne $_.DriverDate) { $_.DriverDate.ToUniversalTime().ToString('o') } else { $null }
            reported_adapter_ram_bytes = $_.AdapterRAM
            status = $_.Status
        }
    })
    Write-JsonFile 'system.json' @{
        windows = @{ name = $os.Caption; version = $os.Version; build = $os.BuildNumber; architecture = $os.OSArchitecture }
        memory = @{ total_physical_kib = $os.TotalVisibleMemorySize; available_physical_kib = $os.FreePhysicalMemory; total_virtual_kib = $os.TotalVirtualMemorySize; available_virtual_kib = $os.FreeVirtualMemory }
        processors = $cpu
        graphics = $gpu
        adapter_ram_note = 'Win32_VideoController.AdapterRAM may truncate VRAM above 4 GiB; do not interpret this field as an authoritative VRAM capacity.'
    }
} catch {
    $issues.Add('Could not read Windows/hardware information: ' + $_.Exception.Message)
}

# Read exactly the configured Godot user://logs folder, not the wider userdata
# tree. FileShare.ReadWrite permits collection while the game is still running.
$logRoot = Join-Path $env:APPDATA 'Godot/app_userdata/灰烬王国 · 中世纪乱斗/logs'
$logInventory = @()
if (Test-Path -LiteralPath $logRoot -PathType Container) {
    $destinationLogs = Join-Path $sessionRoot 'game-logs'
    [IO.Directory]::CreateDirectory($destinationLogs) | Out-Null
    foreach ($log in @(Get-ChildItem -LiteralPath $logRoot -File -Filter '*.log')) {
        $inputStream = $null
        $outputStream = $null
        try {
            if (($log.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $issues.Add('Skipped linked log file: ' + $log.Name)
                continue
            }
            $inputStream = [IO.File]::Open($log.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
            $outputStream = [IO.File]::Open((Join-Path $destinationLogs $log.Name), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $inputStream.CopyTo($outputStream)
            $logInventory += [PSCustomObject]@{ name = $log.Name; copied_bytes = $outputStream.Length; source_last_write_utc = $log.LastWriteTimeUtc.ToString('o') }
        } catch {
            $issues.Add('Could not copy game log ' + $log.Name + ': ' + $_.Exception.Message)
        } finally {
            if ($null -ne $outputStream) { $outputStream.Dispose() }
            if ($null -ne $inputStream) { $inputStream.Dispose() }
        }
    }
} else {
    $issues.Add('No game user://logs directory exists yet.')
}
Write-JsonFile 'game-logs-index.json' @{ files = @($logInventory) }

# Only keep Application Error / Hang / WER records whose event payload names this game
# or a Godot executable. No unrelated application events enter the archive.
$events = @()
$startTime = (Get-Date).AddDays(-7)
try {
    $candidates = @(Get-WinEvent -FilterHashtable @{
        LogName = 'Application'
        ProviderName = @('Application Error', 'Application Hang', 'Windows Error Reporting')
        StartTime = $startTime
    } -ErrorAction Stop)
    foreach ($event in $candidates) {
        [xml]$eventXml = $event.ToXml()
        $namespace = [Xml.XmlNamespaceManager]::new($eventXml.NameTable)
        $namespace.AddNamespace('e', $eventXml.DocumentElement.NamespaceURI)
        $dataNodes = $eventXml.SelectNodes('/e:Event/e:EventData/e:Data', $namespace)
        $dataValues = @($dataNodes | ForEach-Object { $_.InnerText })
        $matching = $false
        foreach ($value in $dataValues) {
            if (Test-GameExecutableName $value) { $matching = $true; break }
        }
        if (-not $matching) { continue }
        $events += [PSCustomObject]@{
            time_utc = $event.TimeCreated.ToUniversalTime().ToString('o')
            event_id = $event.Id
            provider = $event.ProviderName
            message = $event.Message
            data = @($dataNodes | ForEach-Object {
                [PSCustomObject]@{ name = $_.GetAttribute('Name'); value = $_.InnerText }
            })
        }
    }
} catch {
    if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') {
        $issues.Add('Could not read recent game crash/hang events: ' + $_.Exception.Message)
    }
}
Write-JsonFile 'crash-events.json' @{ since_utc = $startTime.ToUniversalTime().ToString('o'); events = @($events) }

# Memory dumps can contain private player data. Record only filenames/sizes/times
# in the standard CrashDumps directory, never dump contents or other WER folders.
$dumpRoot = Join-Path $env:LOCALAPPDATA 'CrashDumps'
$dumpInventory = @()
if (Test-Path -LiteralPath $dumpRoot -PathType Container) {
    try {
        foreach ($dump in @(Get-ChildItem -LiteralPath $dumpRoot -File | Where-Object { $_.Name -match '^(?:AshenCrown|Godot)[._-].*\.dmp$' })) {
            $dumpInventory += [PSCustomObject]@{ name = $dump.Name; bytes = $dump.Length; last_write_utc = $dump.LastWriteTimeUtc.ToString('o') }
        }
    } catch {
        $issues.Add('Could not list game crash dump metadata: ' + $_.Exception.Message)
    }
}
Write-JsonFile 'crash-dumps-index.json' @{ contents_copied = $false; files = @($dumpInventory) }
Write-JsonFile 'collection-status.json' @{
    captured_utc = (Get-Date).ToUniversalTime().ToString('o')
    collected_game_logs = $logInventory.Count
    matching_crash_events = $events.Count
    listed_crash_dumps = $dumpInventory.Count
    warnings = @($issues.ToArray())
    uploaded = $false
    settings_changed = $false
}

$readme = @'
ASHEN CROWN - LOCAL DIAGNOSTICS

This archive contains game logs, recent game/Godot crash/hang event records, Windows,
GPU and memory information, and the installed EXE/PCK versions and SHA-256 hashes.
Crash dump contents, credentials, save files and player settings are not copied.
No information has been uploaded. No setting or process has been changed.

Review the files before sharing: game logs and Windows crash/hang events can include
local file paths, connection addresses or room details. Send the ZIP manually to
the developer together with what you were doing just before the crash.

collection-status.json records any unavailable data. Logs copied from a running
game are a snapshot and may end with an incomplete final line.
'@
[IO.File]::WriteAllText((Join-Path $sessionRoot 'README.txt'), $readme, [Text.UTF8Encoding]::new($false))
$archive = Join-Path $outputRoot ($sessionName + '.zip')
Compress-Archive -LiteralPath $sessionRoot -DestinationPath $archive -CompressionLevel Optimal
Write-Host ('Diagnostics saved locally: ' + $archive)
if ($issues.Count -gt 0) { Write-Warning ('Collection finished with ' + $issues.Count + ' warning(s); see collection-status.json.') }
Get-Item -LiteralPath $archive | Select-Object FullName, Length
