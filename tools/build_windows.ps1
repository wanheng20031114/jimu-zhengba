param([string]$GodotPath = 'C:/Program Files/Godot/Godot_console.exe')

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $projectRoot 'builds/windows'
$executable = Join-Path $buildRoot 'AshenCrown.exe'
$archive = Join-Path $projectRoot 'builds/AshenCrown-Windows-x64.zip'

New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
$exportLog = Join-Path $projectRoot '.local/windows-export.engine.log'
New-Item -ItemType Directory -Path (Split-Path -Parent $exportLog) -Force | Out-Null
& $GodotPath --headless --path $projectRoot --log-file $exportLog --export-release 'Windows Desktop' $executable
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
        foreach ($packageName in @('AshenCrown.exe', 'AshenCrown.pck', 'START_HERE.txt', 'collect_diagnostics.ps1', 'COLLECT_DIAGNOSTICS.cmd')) {
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($packageZip, (Join-Path $buildRoot $packageName), ('windows/' + $packageName), [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally {
        $packageZip.Dispose()
    }
} finally {
    $packageStream.Dispose()
}
Get-Item -LiteralPath $executable, $archive | Select-Object FullName, Length
