param(
    [string]$Python='',
    [string]$ModelSimBin='C:/modelsim/modeltech64_10.6e/win64',
    [string]$Gowin='C:/Gowin/Gowin_V1.9.12_x64/IDE/bin/gw_sh.exe',
    [switch]$Build
)
# 验证入口只编译/仿真，不扫描或下载板卡；源码、约束、旧位流均保留。
$ErrorActionPreference='Stop'
$taskRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if(!$Python){
    $Python=Join-Path $taskRoot 'tmp/desktop-python/Scripts/python.exe'
    if(!(Test-Path -LiteralPath $Python)){$Python='python'}
}
$taskRun=Join-Path $taskRoot ('verification/timing-latency-20261026/run_'+(Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $taskRun -Force | Out-Null
$taskStageJson=Join-Path $taskRun 'stage.json'
& $Python (Join-Path $PSScriptRoot 'prepare-direct-score-verification.py') --output $taskStageJson
if($LASTEXITCODE -ne 0){throw 'Could not freeze timing/latency sources'}
$taskStage=(Get-Content -LiteralPath $taskStageJson -Raw | ConvertFrom-Json).stage
$taskBaseline=Join-Path $taskRoot 'delivery-oled-integration/evidence/fpga/build-results.json'
if(!(Test-Path -LiteralPath $taskBaseline)){
    $taskBaseline=Join-Path $taskRoot 'verification/oled-baseline.json'
}
if(Test-Path -LiteralPath $taskBaseline){
    Copy-Item -LiteralPath $taskBaseline -Destination (Join-Path $taskStage 'verification/oled-baseline.json')
}
try {
    & (Join-Path $taskStage 'scripts/test-modelsim-full.ps1') -ModelSimBin $ModelSimBin -TimeoutSeconds 1200 `
        -CaseName @('transport_status_equivalence','polar_margin_s1','polar_margin_s2','polar_margin_s3',
            'polar_margin_negative','polar_margin_early_write','touch_i2s_latency','oled_timing_regression',
            'menu_system','learning_mode','learning_status','learning_system','direct_score','direct_system',
            'performance','performance_retrigger','performance_commit','global_panic',
            'mpr121_backpressure','mpr121_capacity','audio_i2s','full_system','menu_replay','score_capacity_1024') `
        -OutputRoot (Join-Path $taskStage 'verification/modelsim-margin')
    if($LASTEXITCODE -ne 0){throw 'Timing/latency ModelSim regression failed'}
    $taskLatest=Get-ChildItem -LiteralPath (Join-Path $taskStage 'verification/modelsim-margin') -Directory |
        Sort-Object Name | Select-Object -Last 1
    & $Python (Join-Path $PSScriptRoot 'analyze-touch-i2s-latency.py') `
        (Join-Path $taskLatest.FullName 'sim/audio_results/touch_i2s_latency.csv') (Join-Path $taskRun 'analysis')
    if($LASTEXITCODE -ne 0){throw 'Latency timestamp analysis failed'}
    if($Build){
        & $Python (Join-Path $taskStage 'scripts/build-contest-isolated.py') --variant timing-latency `
            --without-gao --gowin $Gowin --baseline (Join-Path $taskStage 'verification/oled-baseline.json') `
            --output-root (Join-Path $taskStage 'verification/build')
        if($LASTEXITCODE -ne 0){throw 'Build/timing failed; no new bitstream acceptance'}
    }
} finally {
    Write-Output "隔离验证现场：$taskStage"
    Write-Output "输入清单：$taskStageJson"
}
