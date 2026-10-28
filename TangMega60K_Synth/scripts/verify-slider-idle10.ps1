param(
    [string]$Python = 'python',
    [string]$ModelSimBin = 'C:/modelsim/modeltech64_10.6e/win64',
    [string]$StageParent = '',
    [switch]$Build
)
# 独立测试：不连接硬件、不覆盖旧实现；10秒显示不等于核心板熄灯故障已修复。
$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$taskRun = Join-Path $taskRoot ('verification/slider-idle10-20261028/run_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Force -Path $taskRun | Out-Null
$taskStageFile = Join-Path $taskRun 'stage.json'
$taskArgs = @((Join-Path $PSScriptRoot 'prepare-direct-score-verification.py'),'--output',$taskStageFile)
if ($StageParent) { $taskArgs += @('--stage-parent',$StageParent) }
& $Python @taskArgs
if ($LASTEXITCODE -ne 0) { throw 'Snapshot failed' }
$taskStage = (Get-Content -LiteralPath $taskStageFile -Raw | ConvertFrom-Json).stage
$taskCases = @('oled_idle10','slider_liveness','oled_i2c_stream','oled_wave_capture','oled_idle_menu',
    'oled_wave_display','oled_wave_board','oled_wave_board_timing','oled_volume','oled_menu',
    'oled_volume_board','slider_menu','slider_performance','slider_volume_control','slider_volume_system',
    'menu_system','menu_replay','mode_status','global_panic','control_router','expression_merge',
    'audio_boot_status','audio_i2s','headroom_smoothing_n64','learning_system',
    'mpr121_frontend','mpr121_backpressure','mpr121_capacity','transport_status_equivalence')
& (Join-Path $taskStage 'scripts/test-modelsim-full.ps1') -ModelSimBin $ModelSimBin `
    -CaseName $taskCases -TimeoutSeconds 1200 -OutputRoot (Join-Path $taskStage 'verification/slider-idle10-modelsim')
if ($LASTEXITCODE -ne 0) { throw 'Regression failed; do not publish as passed' }
$taskLatest = Get-ChildItem -LiteralPath (Join-Path $taskStage 'verification/slider-idle10-modelsim') -Directory |
    Sort-Object Name | Select-Object -Last 1
& $Python (Join-Path $taskRoot 'scripts/analyze-oled-wave.py') `
    (Join-Path $taskLatest.FullName 'sim/audio_results') (Join-Path $taskRun 'analysis')
if ($LASTEXITCODE -ne 0) { throw 'Independent I2S/OLED pixel comparison failed' }
[pscustomobject]@{stage=$taskStage;modelsim=$taskLatest.FullName;cases=$taskCases;hardwareTested=$false} |
    ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $taskRun 'verification-result.json') -Encoding utf8
if ($Build) {
    & $Python (Join-Path $taskStage 'scripts/build-contest-isolated.py') --variant slider-idle10 `
        --without-gao --baseline (Join-Path $taskRoot 'docs/reports/oled-idle-wave-20261027/selected-r2/build-results.json') `
        --output-root (Join-Path $taskStage 'verification/slider-idle10-build')
    if ($LASTEXITCODE -ne 0) { throw 'Build or timing failed; do not use bitstream' }
}
Write-Output "Stage: $taskStage"
Write-Output "Run: $taskRun"
