param(
    [string]$Python='',
    [string]$ModelSimBin='C:/modelsim/modeltech64_10.6e/win64',
    [string]$Gowin='C:/Gowin/Gowin_V1.9.12_x64/IDE/bin/gw_sh.exe',
    [switch]$Build
)
# 独立英文路径验证，不扫描/下载板卡；保留原full/impl及旧LearningMode交付。
$ErrorActionPreference='Stop'
$taskRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if(!$Python){
    $Python=Join-Path $taskRoot 'tmp/desktop-python/Scripts/python.exe'
    if(!(Test-Path -LiteralPath $Python)){$Python='python'}
}
$taskRun=Join-Path $taskRoot ('verification/oled-integration/run_'+(Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $taskRun -Force | Out-Null
& $Python (Join-Path $PSScriptRoot 'check-oled-pin-map.py') |
    Out-File -LiteralPath (Join-Path $taskRun 'pin-check.json') -Encoding UTF8
if($LASTEXITCODE -ne 0){throw 'OLED pin map check failed'}
$taskStageManifest=Join-Path $taskRun 'stage.json'
& $Python (Join-Path $PSScriptRoot 'prepare-direct-score-verification.py') --output $taskStageManifest
if($LASTEXITCODE -ne 0){throw 'Could not create OLED verification snapshot'}
$taskStage=(Get-Content -LiteralPath $taskStageManifest -Raw | ConvertFrom-Json).stage
$taskBaseline=Join-Path $taskStage 'verification/baseline.json'
$taskLearningBaseline=Join-Path $taskRoot 'verification/learning-mode/build-results.json'
if(!(Test-Path -LiteralPath $taskLearningBaseline)){
    $taskLearningBaseline=Join-Path $taskRoot 'delivery-learning-mode/evidence/fpga/build-results.json'
}
if(Test-Path -LiteralPath $taskLearningBaseline){
    $taskBaseline=Join-Path $taskStage 'verification/learning-baseline.json'
    Copy-Item -LiteralPath $taskLearningBaseline -Destination $taskBaseline
}
try{
    & (Join-Path $taskStage 'scripts/test-modelsim-full.ps1') -ModelSimBin $ModelSimBin `
        -CaseName @('oled_timing_regression','oled_board','oled_board_timing',
            'learning_system','direct_system','menu_system','oled_menu','global_panic',
            'performance','performance_retrigger','performance_commit','performance_stage',
            'score_capacity_1024','learning_mode','learning_status','control_router',
            'menu_replay','mpr121_backpressure','mpr121_capacity','full_system') `
        -OutputRoot (Join-Path $taskStage 'verification/modelsim')
    if($LASTEXITCODE -ne 0){throw 'OLED ModelSim regression failed'}
    $taskLatest=Get-ChildItem -LiteralPath (Join-Path $taskStage 'verification/modelsim') -Directory |
        Sort-Object Name | Select-Object -Last 1
    & $Python (Join-Path $PSScriptRoot 'verify-oled-integration.py') `
        (Join-Path $taskLatest.FullName 'sim/audio_results/oled_board_frame.hex') (Join-Path $taskRun 'preview')
    if($LASTEXITCODE -ne 0){throw 'OLED board frame mismatch'}
    if($Build){
        & $Python (Join-Path $taskStage 'scripts/build-contest-isolated.py') --variant oled-integration `
            --without-gao --gowin $Gowin --baseline $taskBaseline `
            --output-root (Join-Path $taskStage 'verification/build')
        if($LASTEXITCODE -ne 0){throw 'OLED build or timing failed; candidate is not ready for delivery'}
    }
}finally{
    Write-Output "完整验证现场：$taskStage"
    Write-Output "输入清单：$taskStageManifest"
}
