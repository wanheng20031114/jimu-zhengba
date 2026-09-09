param(
    [string]$GodotPath = 'C:/Program Files/Godot/Godot_console.exe',
    [switch]$PackOnly,
    [ValidatePattern('^$|^[0-9]+\.[0-9]+\.[0-9]+$')][string]$VersionedOutput = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $projectRoot ('builds/windows' + $(if ($VersionedOutput) { '-' + $VersionedOutput } else { '' }))
$executable = Join-Path $buildRoot '积木争霸.exe'
$archive = Join-Path $projectRoot ('builds/积木争霸-' + $(if ($VersionedOutput) { $VersionedOutput + '-' } else { '' }) + 'Windows-x64.zip')
if ($VersionedOutput) {
    $presetText = Get-Content -LiteralPath (Join-Path $projectRoot 'export_presets.cfg') -Raw -Encoding UTF8
    $presetVersion = [regex]::Match($presetText, '(?m)^application/file_version="([^"]+)"').Groups[1].Value
    if ($presetVersion -ne ($VersionedOutput + '.0')) { throw 'Versioned output must match the configured Windows release version.' }
}

New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
$exportLog = Join-Path $projectRoot '.local/windows-export.engine.log'
New-Item -ItemType Directory -Path (Split-Path -Parent $exportLog) -Force | Out-Null
if ($PackOnly) {
    # Reuse the current version's launcher when only project resources changed.
    # This also avoids replacing an identical EXE while the user is playing it.
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'Pack-only export requires an existing Windows launcher from this version.' }
    $releaseVersionMatch = [regex]::Match((Get-Content -LiteralPath (Join-Path $projectRoot 'export_presets.cfg') -Raw -Encoding UTF8), '(?m)^application/file_version="([^"]+)"')
    $launcherVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($executable).FileVersion
    if (-not $releaseVersionMatch.Success -or $launcherVersion -ne $releaseVersionMatch.Groups[1].Value) { throw 'Launcher version differs from the export preset; run a full export first.' }
    & $GodotPath --headless --path $projectRoot --log-file $exportLog --export-pack 'Windows Desktop' (Join-Path $buildRoot '积木争霸.pck')
} else {
    & $GodotPath --headless --path $projectRoot --log-file $exportLog --export-release 'Windows Desktop' $executable
}
if ($LASTEXITCODE -ne 0) { throw 'Godot Windows export failed.' }
Copy-Item -LiteralPath (Join-Path $projectRoot 'docs/windows-readme.txt') -Destination (Join-Path $buildRoot 'START_HERE.txt') -Force
foreach ($supportFile in @('collect_diagnostics.ps1', 'COLLECT_DIAGNOSTICS.cmd')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $supportFile) -Destination (Join-Path $buildRoot $supportFile) -Force
}
# Godot or Windows may retain a replaced executable as an .exe~*.TMP file.
# Publish only the five deliverables while preserving the windows/ directory.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$packageStream = [System.IO.File]::Open($archive, [System.IO.FileMode]::Create)
try {
    $packageZip = [System.IO.Compression.ZipArchive]::new($packageStream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        foreach ($packageName in @('积木争霸.exe', '积木争霸.pck', 'START_HERE.txt', 'collect_diagnostics.ps1', 'COLLECT_DIAGNOSTICS.cmd')) {
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($packageZip, (Join-Path $buildRoot $packageName), ('windows/' + $packageName), [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally {
        $packageZip.Dispose()
    }
} finally {
    $packageStream.Dispose()
}
Get-Item -LiteralPath $executable, $archive | Select-Object FullName, Length
