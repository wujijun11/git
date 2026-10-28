param(
    [string]$Python='python',
    [string]$ModelSimBin='C:/modelsim/modeltech64_10.6e/win64',
    [switch]$Build
)
# 独立快照验证；不扫描/下载硬件，不覆盖旧位流或原full/impl。
$ErrorActionPreference='Stop'
$taskRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$taskRun=Join-Path $taskRoot ('verification/menu-hierarchy-20261028/run_'+(Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Force -Path $taskRun | Out-Null
$taskStageFile=Join-Path $taskRun 'stage.json'
& $Python (Join-Path $PSScriptRoot 'prepare-direct-score-verification.py') --output $taskStageFile
if($LASTEXITCODE -ne 0){throw 'Independent snapshot failed'}
$taskStage=(Get-Content -LiteralPath $taskStageFile -Raw | ConvertFrom-Json).stage
$taskCases=@('hierarchy_board_timing','hierarchy_pixels','hierarchy_system','hierarchy_board',
    'menu_hierarchy','slider_expression','oled_idle10','slider_liveness','oled_i2c_stream',
    'oled_wave_capture','oled_idle_menu','oled_wave_display','oled_wave_board','oled_wave_board_timing',
    'oled_volume','oled_menu','oled_volume_board','slider_menu','slider_performance',
    'slider_volume_control','slider_volume_system','menu_system','menu_replay','mode_status',
    'global_panic','control_router','expression_merge','audio_boot_status','audio_i2s',
    'headroom_smoothing_n64','learning_system','mpr121_frontend','mpr121_backpressure',
    'mpr121_capacity','transport_status_equivalence','runtime_fx')
& (Join-Path $taskStage 'scripts/test-modelsim-full.ps1') -ModelSimBin $ModelSimBin `
    -CaseName $taskCases -TimeoutSeconds 1200 -OutputRoot (Join-Path $taskStage 'verification/menu-hierarchy-modelsim')
if($LASTEXITCODE -ne 0){throw 'ModelSim regression failed; do not claim pass'}
$taskLatest=Get-ChildItem -LiteralPath (Join-Path $taskStage 'verification/menu-hierarchy-modelsim') -Directory |
    Sort-Object Name | Select-Object -Last 1
# 新旧顶层用例共用输出文件名；独立复跑新顶层封存，避免旧入口覆盖新波形证据。
& (Join-Path $taskStage 'scripts/test-modelsim-full.ps1') -ModelSimBin $ModelSimBin `
    -CaseName hierarchy_board -TimeoutSeconds 1200 -OutputRoot (Join-Path $taskStage 'verification/menu-hierarchy-wave-capture')
if($LASTEXITCODE -ne 0){throw 'Dedicated production hierarchy waveform capture failed'}
$taskCapture=Get-ChildItem -LiteralPath (Join-Path $taskStage 'verification/menu-hierarchy-wave-capture') -Directory |
    Sort-Object Name | Select-Object -Last 1
& $Python (Join-Path $taskRoot 'scripts/analyze-hierarchy-oled.py') `
    (Join-Path $taskLatest.FullName 'sim/audio_results/oled_hierarchy_pixels.csv') (Join-Path $taskRun 'menu-preview')
if($LASTEXITCODE -ne 0){throw 'Independent menu text/pixel verification failed'}
& $Python (Join-Path $taskRoot 'scripts/analyze-oled-wave.py') `
    (Join-Path $taskCapture.FullName 'sim/audio_results') (Join-Path $taskRun 'wave-preview')
if($LASTEXITCODE -ne 0){throw 'Independent I2S/OLED reference failed'}
[pscustomobject]@{stage=$taskStage;modelsim=$taskLatest.FullName;captureModelSim=$taskCapture.FullName;
    cases=$taskCases;hardwareTested=$false} |
    ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $taskRun 'verification-result.json') -Encoding utf8
if($Build){
    & $Python (Join-Path $taskStage 'scripts/build-contest-isolated.py') --variant menu-hierarchy --without-gao `
        --baseline (Join-Path $taskRoot 'docs/reports/slider-idle10-20261028/selected/build-results.json') `
        --output-root (Join-Path $taskStage 'verification/menu-hierarchy-build')
    if($LASTEXITCODE -ne 0){throw 'Build/timing failed; do not use generated bitstream'}
}
Write-Output "Stage: $taskStage"
Write-Output "Run: $taskRun"
