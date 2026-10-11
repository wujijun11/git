[CmdletBinding()]
param([string]$OutputDir='')
$ErrorActionPreference='Stop'
$projectDir=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (!$OutputDir) { $OutputDir=Join-Path $projectDir 'release/contest-full-20261011' }
$OutputDir=[IO.Path]::GetFullPath($OutputDir)
$pnr=Join-Path $projectDir 'full/impl/pnr'
$timingPath=Join-Path $pnr 'ContestFull.tr'
$timing=Get-Content -LiteralPath $timingPath -Raw
foreach ($kind in @('Setup','Hold')) {
    $match=[regex]::Match($timing,"<Numbers of $kind Violated Endpoints>:\s*(\d+)")
    if (!$match.Success -or [int]$match.Groups[1].Value -ne 0) {
        throw "Refusing to export a build with missing or failing $kind timing"
    }
}
$fullDir=Join-Path $projectDir 'full'
[xml]$project=Get-Content -LiteralPath (Join-Path $fullDir 'ContestFull.gprj') -Raw
$inputs=@($project.Project.FileList.File | Where-Object { $_.enable -eq '1' } | ForEach-Object {
    [IO.Path]::GetFullPath((Join-Path $fullDir $_.path))
})
$inputs+=@(Get-ChildItem -LiteralPath (Join-Path $projectDir 'rtl/audio/rom') -File -Filter '*.hex' | ForEach-Object FullName)
$inputs+=Join-Path $projectDir 'rtl/visual/goertzel_1024_64.hex'
$inputs+=Join-Path $fullDir 'ContestFull.gprj'
$inputs+=Join-Path $projectDir 'scripts/build-contest-full.tcl'
$reportTime=(Get-Item -LiteralPath $timingPath).LastWriteTimeUtc
foreach ($inputPath in $inputs) {
    if ((Get-Item -LiteralPath $inputPath).LastWriteTimeUtc -gt $reportTime) {
        throw "Source changed after timing report: $inputPath. Rebuild before export."
    }
}
$apk=Join-Path $projectDir 'mobile/android/output/TangSynthRemote-debug.apk'
$apkTime=(Get-Item -LiteralPath $apk).LastWriteTimeUtc
$androidInputs=@(Get-ChildItem -LiteralPath (Join-Path $projectDir 'mobile/android/app/src'),(Join-Path $projectDir 'mobile/web') -File -Recurse)
$androidInputs+=@(Get-Item -LiteralPath (Join-Path $projectDir 'mobile/android/build.gradle'),(Join-Path $projectDir 'mobile/android/app/build.gradle'),(Join-Path $projectDir 'mobile/android/settings.gradle'))
foreach ($androidInput in $androidInputs) {
    if ($androidInput.LastWriteTimeUtc -gt $apkTime) { throw "Phone source changed after APK: $($androidInput.FullName). Rebuild before export." }
}
$inputs+=@($androidInputs | ForEach-Object FullName)
$lintPath=Join-Path $projectDir 'mobile/android/app/build/reports/lint-results-debug.xml'
[xml]$lint=Get-Content -LiteralPath $lintPath -Raw
if (@($lint.issues.issue | Where-Object { $_.severity -eq 'Error' -or $_.severity -eq 'Fatal' }).Count) {
    throw 'Android lint has errors; refusing to export APK'
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Copy-Item -LiteralPath (Join-Path $pnr 'ContestFull.fs') -Destination $OutputDir -Force
Copy-Item -LiteralPath $timingPath -Destination $OutputDir -Force
Copy-Item -LiteralPath (Join-Path $pnr 'ContestFull.rpt.txt') -Destination $OutputDir -Force
Copy-Item -LiteralPath $apk -Destination $OutputDir -Force
Copy-Item -LiteralPath $lintPath -Destination $OutputDir -Force
$documentationFiles=@(
    'docs/全功能工程与官网验收-20261011.md',
    'docs/全功能首次上板步骤-20261011.md',
    'docs/工程复查与优化-20261011.md',
    'docs/mpr121-implementation.md',
    'docs/performance-implementation.md',
    'docs/remote-implementation.md',
    'docs/remote-control-v1.md',
    'docs/hardware/PR1014-clock-investigation-20260922.md',
    'hardware/touch25/assembly_wiring_zh.md',
    'hardware/touch25/harness_assembly_zh.md',
    'hardware/touch25/harness_layout.png',
    'hardware/touch25/harness_layout.svg',
    'hardware/touch25/calibration_guide_zh.md',
    'hardware/touch25/touch25_driver_handoff_zh.md',
    'hardware/touch25/mapping.csv',
    'hardware/slider4/README.md',
    'hardware/slider4/design_overview.svg',
    'firmware/ble_bridge/ble_bridge.ino',
    'firmware/ble_bridge/README.md'
)
foreach ($relativePath in $documentationFiles) {
    $sourcePath=Join-Path $projectDir $relativePath
    $destinationPath=Join-Path $OutputDir $relativePath
    New-Item -ItemType Directory -Force -Path (Split-Path $destinationPath) | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
    $inputs+=$sourcePath
}
# Retain the old delivery entry link while keeping relative document links
# under the same docs/hardware layout as the source project.
'# 全功能交付说明' + "`n`n" + '[官网要求、证据和接线](docs/全功能工程与官网验收-20261011.md)' + "`n`n" + '[首次上板与到货验收](docs/全功能首次上板步骤-20261011.md)' | Set-Content -LiteralPath (Join-Path $OutputDir '全功能工程与官网验收-20261011.md') -Encoding utf8
$bleManifestPath=Join-Path $projectDir 'firmware/ble_bridge/output/build-manifest.json'
$bleIncluded=$false
if (Test-Path -LiteralPath $bleManifestPath) {
    $ble=Get-Content -LiteralPath $bleManifestPath -Raw | ConvertFrom-Json
    $bleSource=Join-Path $projectDir 'firmware/ble_bridge/ble_bridge.ino'
    if ($ble.sourceSha256 -ne (Get-FileHash -LiteralPath $bleSource -Algorithm SHA256).Hash.ToLower()) {
        throw 'BLE source changed after its binary was compiled. Rebuild before export.'
    }
    if ($ble.core -ne 'esp32:esp32@3.3.5' -or $ble.fqbn -ne 'esp32:esp32:esp32c3:CDCOnBoot=cdc') {
        throw 'BLE build target does not match the supported C3 bridge.'
    }
    $bleDestination=Join-Path $OutputDir 'firmware/ble_bridge/output'
    New-Item -ItemType Directory -Force -Path $bleDestination | Out-Null
    foreach ($artifact in $ble.artifacts) {
        if ([IO.Path]::GetFileName($artifact.name) -ne $artifact.name) { throw 'BLE manifest has an invalid artifact name.' }
        $blePath=Join-Path (Split-Path $bleManifestPath) $artifact.name
        if ((Get-FileHash -LiteralPath $blePath -Algorithm SHA256).Hash.ToLower() -ne $artifact.sha256) {
            throw "BLE artifact hash mismatch: $($artifact.name)"
        }
        Copy-Item -LiteralPath $blePath -Destination $bleDestination -Force
    }
    Copy-Item -LiteralPath $bleManifestPath -Destination $bleDestination -Force
    $bleIncluded=$true
}
$manifest=[ordered]@{
    exportedAtUtc=[DateTime]::UtcNow.ToString('o')
    top='board_contest_full_top'
    device='GW5AT-60B / GW5AT-LV60PG484AC1/I0'
    setupViolations=0;holdViolations=0
    hardwareValidated=$false
    bleBinaryIncluded=$bleIncluded
    note='Check actual dock revision and new pins before downloading. No BLE/LED/HDMI hardware acceptance yet.'
    inputs=@($inputs | Sort-Object -Unique | ForEach-Object {
        [ordered]@{path=[IO.Path]::GetRelativePath($projectDir,$_).Replace('\','/');sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLower()}
    })
    artifacts=@(Get-ChildItem -LiteralPath $OutputDir -File -Recurse | Where-Object { $_.FullName -ne (Join-Path $OutputDir 'manifest.json') } | ForEach-Object {
        [ordered]@{name=[IO.Path]::GetRelativePath($OutputDir,$_.FullName).Replace('\','/');size=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower()}
    })
}
$manifest | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $OutputDir 'manifest.json') -Encoding utf8
Write-Output "Verified local delivery: $OutputDir"
