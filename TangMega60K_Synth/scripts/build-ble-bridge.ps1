[CmdletBinding()]
param(
    [string]$ArduinoCli='',
    [string]$ConfigFile='',
    [string]$BuildDir='',
    [string]$OutputDir=''
)
$ErrorActionPreference='Stop'
$projectDir=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$toolDir=[IO.Path]::GetFullPath((Join-Path $projectDir '../tmp/ble-build'))
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
$fqbn='esp32:esp32:esp32c3:CDCOnBoot=cdc'
$sketch=Join-Path $projectDir 'firmware/ble_bridge'
New-Item -ItemType Directory -Force -Path $BuildDir,$OutputDir | Out-Null
# Arduino-ESP32 3.3.5 Windows savehex hooks still copy metadata into this
# sketch-relative directory even when --output-dir points somewhere else.
New-Item -ItemType Directory -Force -Path (Join-Path $sketch 'build/esp32.esp32.esp32c3') | Out-Null
& $ArduinoCli @commonArgs compile --fqbn $fqbn --jobs 4 --warnings more --build-path $BuildDir --output-dir $OutputDir $sketch
if ($LASTEXITCODE -ne 0) { throw "BLE bridge compilation failed: exit $LASTEXITCODE" }
$binary=Join-Path $OutputDir 'ble_bridge.ino.bin'
if (!(Test-Path -LiteralPath $binary)) { throw 'Compiler did not produce ble_bridge.ino.bin' }
$source=Join-Path $sketch 'ble_bridge.ino'
$manifest=[ordered]@{
    compiledAtUtc=[DateTime]::UtcNow.ToString('o')
    arduinoCli=$cliVersion
    core='esp32:esp32@3.3.5'
    fqbn=$fqbn
    uploaded=$false
    hardwareValidated=$false
    sourceSha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLower()
    artifacts=@(Get-ChildItem -LiteralPath $OutputDir -File | Where-Object Name -ne 'build-manifest.json' | ForEach-Object {
        [ordered]@{name=$_.Name;size=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower()}
    })
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDir 'build-manifest.json') -Encoding utf8
Write-Output "Compiled BLE control bridge: $binary"
Write-Output "SHA256: $((Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLower())"
