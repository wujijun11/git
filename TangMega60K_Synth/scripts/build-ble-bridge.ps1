[CmdletBinding()]
param(
    [string]$ArduinoCli='',
    [string]$ToolRoot='',
    [string]$ConfigFile='',
    [string]$BuildDir='',
    [string]$OutputDir=''
)
$ErrorActionPreference='Stop'
function Get-BridgeSha256([string]$Path) {
    # Use .NET directly so the .cmd entry point also works in Windows
    # PowerShell environments that do not expose Get-FileHash.
    $hashStream=[IO.File]::OpenRead($Path)
    $hashAlgorithm=[Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($hashAlgorithm.ComputeHash($hashStream)).Replace('-','').ToLowerInvariant() }
    finally { $hashStream.Dispose();$hashAlgorithm.Dispose() }
}
$projectDir=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$toolDir=if($ToolRoot){[IO.Path]::GetFullPath($ToolRoot)}else{[IO.Path]::GetFullPath((Join-Path $projectDir '../tmp/ble-build'))}
if (!$ArduinoCli) {
    $localCli=Join-Path $toolDir 'arduino-cli.exe'
    if (Test-Path -LiteralPath $localCli) { $ArduinoCli=$localCli }
    else { $ArduinoCli=(Get-Command arduino-cli -ErrorAction Stop).Source }
}
$ArduinoCli=[IO.Path]::GetFullPath($ArduinoCli)
$commonArgs=@('--no-color')
if (!$ConfigFile -and (Test-Path -LiteralPath (Join-Path $toolDir 'arduino-cli.yaml'))) {
    $ConfigFile=Join-Path $toolDir 'arduino-cli.yaml'
}
if ($ConfigFile) { $commonArgs+=@('--config-file',[IO.Path]::GetFullPath($ConfigFile)) }
if (!$BuildDir) { $BuildDir=Join-Path $toolDir 'build' }
if (!$OutputDir) { $OutputDir=Join-Path $projectDir 'firmware/ble_bridge/output' }
$BuildDir=[IO.Path]::GetFullPath($BuildDir)
$OutputDir=[IO.Path]::GetFullPath($OutputDir)
$cliVersion=(& $ArduinoCli @commonArgs version | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Arduino CLI version check failed' }
$cores=(& $ArduinoCli @commonArgs core list | Out-String)
if ($LASTEXITCODE -ne 0 -or $cores -notmatch '(?m)^esp32:esp32\s+3\.3\.5\s') {
    throw "Install Espressif Arduino-ESP32 3.3.5 before building this bridge. Installed cores:`n$cores"
}
$fqbn='esp32:esp32:waveshare_esp32_c3_zero:CDCOnBoot=default,FlashSize=4M'
$sketch=Join-Path $projectDir 'firmware/ble_bridge'
$bridgeBleLibrary=Join-Path $projectDir 'firmware/libraries/BridgeBLE'
if (!(Test-Path -LiteralPath (Join-Path $bridgeBleLibrary 'src/BLECharacteristic.cpp')) -or
    !(Test-Path -LiteralPath (Join-Path $bridgeBleLibrary 'library.properties'))) {
    throw 'The project-local checked BLE library is required; do not silently build with the unpatched SDK wrapper.'
}
New-Item -ItemType Directory -Force -Path $BuildDir,$OutputDir | Out-Null
# Arduino-ESP32 3.3.5 Windows savehex hooks still copy metadata into this
# sketch-relative directory even when --output-dir points somewhere else.
New-Item -ItemType Directory -Force -Path (Join-Path $sketch 'build/esp32.esp32.waveshare_esp32_c3_zero') | Out-Null
$source=Join-Path $sketch 'ble_bridge.ino'
function Get-BridgeSourceFiles {
    @(Get-ChildItem -LiteralPath $sketch -File | Where-Object Extension -in '.ino','.h','.hpp','.cpp','.c' | Sort-Object Name | ForEach-Object {
        [ordered]@{name=$_.Name;sha256=(Get-BridgeSha256 $_.FullName)}
    })
}
function Get-BridgeLibraryFiles {
    @(Get-ChildItem -LiteralPath $bridgeBleLibrary -File -Recurse | Sort-Object FullName | ForEach-Object {
        [ordered]@{path=$_.FullName.Substring($projectDir.Length+1).Replace('\','/');sha256=(Get-BridgeSha256 $_.FullName)}
    })
}
$sourceFilesBefore=@(Get-BridgeSourceFiles)
$libraryFilesBefore=@(Get-BridgeLibraryFiles)
$buildLog=Join-Path $toolDir 'compile-local.log'
Write-Output "Compiling the Waveshare ESP32-C3-Zero bridge. This does not upload firmware."
Write-Output "Build log: $buildLog"
& $ArduinoCli @commonArgs compile --fqbn $fqbn --jobs 4 --warnings more --library $bridgeBleLibrary --build-path $BuildDir --output-dir $OutputDir $sketch *> $buildLog
$compileExit=$LASTEXITCODE
$compileExit | Set-Content -LiteralPath (Join-Path $toolDir 'compile-local.exit.txt') -Encoding ascii
Get-Content -LiteralPath $buildLog | Write-Output
if ($compileExit -ne 0) { throw "BLE bridge compilation failed: exit $compileExit" }
$binary=Join-Path $OutputDir 'ble_bridge.ino.bin'
if (!(Test-Path -LiteralPath $binary)) { throw 'Compiler did not produce ble_bridge.ino.bin' }
$sourceFilesAfter=@(Get-BridgeSourceFiles)
$libraryFilesAfter=@(Get-BridgeLibraryFiles)
if (($sourceFilesBefore | ConvertTo-Json -Compress) -cne ($sourceFilesAfter | ConvertTo-Json -Compress)) {
    throw 'Bridge source changed during compilation. Rebuild before exporting a manifest.'
}
if (($libraryFilesBefore | ConvertTo-Json -Compress) -cne ($libraryFilesAfter | ConvertTo-Json -Compress)) {
    throw 'The project-local BLE library changed during compilation. Rebuild before exporting a manifest.'
}
# --library explicitly selects the pinned wrapper. Verify actual compiler inputs
# as well, so a dependency resolver change cannot silently restore the old race.
$compilationDatabase=Join-Path $BuildDir 'compile_commands.json'
if (!(Test-Path -LiteralPath $compilationDatabase)) { throw 'Missing compiler input database; cannot verify BLE library selection.' }
$compiledFiles=@(Get-Content -LiteralPath $compilationDatabase -Raw | ConvertFrom-Json | ForEach-Object { [IO.Path]::GetFullPath($_.file) })
$localLibraryCpp=@(Get-ChildItem -LiteralPath (Join-Path $bridgeBleLibrary 'src') -Filter '*.cpp' -File -Recurse)
foreach ($librarySource in $localLibraryCpp) {
    if ($compiledFiles -notcontains $librarySource.FullName) { throw "Project-local BLE input was not selected: $($librarySource.Name)" }
}
if (@($compiledFiles | Where-Object { $_ -match '[\\/]libraries[\\/]BLE[\\/]src[\\/]' }).Count -ne 0) {
    throw 'Compiler input database still selects an unpatched SDK BLE source.'
}
$manifest=[ordered]@{
    compiledAtUtc=[DateTime]::UtcNow.ToString('o')
    arduinoCli=$cliVersion
    core='esp32:esp32@3.3.5'
    fqbn=$fqbn
    board='Waveshare ESP32-C3-Zero / ESP32-C3-Zero-M'
    uart=[ordered]@{rxGpio=6;txGpio=7;baud=115200;format='8N1';wirePacketBytes=16}
    statusRgbGpio=10
    flashBytes=4194304
    exitCode=$compileExit
    uploaded=$false
    hardwareValidated=$false
    sourceSha256=($sourceFilesBefore | Where-Object name -eq 'ble_bridge.ino').sha256
    sourceFiles=$sourceFilesBefore
    bleLibrary=[ordered]@{path='firmware/libraries/BridgeBLE';upstream='arduino-esp32 3.3.5';selectionVerified=$true;compiledCppFiles=$localLibraryCpp.Count}
    libraryFiles=$libraryFilesBefore
    artifacts=@(Get-ChildItem -LiteralPath $OutputDir -File | Where-Object Name -ne 'build-manifest.json' | ForEach-Object {
        [ordered]@{name=$_.Name;size=$_.Length;sha256=(Get-BridgeSha256 $_.FullName)}
    })
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDir 'build-manifest.json') -Encoding utf8
Write-Output "Compiled BLE control bridge: $binary"
Write-Output "SHA256: $(Get-BridgeSha256 $binary)"
