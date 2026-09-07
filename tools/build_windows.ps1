param([string]$GodotPath = 'C:/Program Files/Godot/Godot_console.exe')

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $projectRoot 'builds/windows'
$executable = Join-Path $buildRoot 'AshenCrown.exe'
$archive = Join-Path $projectRoot 'builds/AshenCrown-Windows-x64.zip'

New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
& $GodotPath --headless --path $projectRoot --export-release 'Windows Desktop' $executable
if ($LASTEXITCODE -ne 0) { throw 'Godot Windows export failed.' }
Copy-Item -LiteralPath (Join-Path $projectRoot 'docs/windows-readme.txt') -Destination (Join-Path $buildRoot 'START_HERE.txt') -Force
Compress-Archive -LiteralPath $buildRoot -DestinationPath $archive -Force
Get-Item -LiteralPath $executable, $archive | Select-Object FullName, Length
