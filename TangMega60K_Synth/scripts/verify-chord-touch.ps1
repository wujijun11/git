param(
    [string]$Python='python',
    [string]$ModelSimBin='C:/modelsim/modeltech64_10.6e/win64',
    [ValidateSet('Core','Regression','All')][string]$Group='All',
    [string]$Stage='',
    [switch]$Build
)
# 本地可复现验证：独立英文源码副本；不扫描下载器、不下载板卡、不推送远端。
$ErrorActionPreference='Stop'
$taskRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if(!$Stage){
    $taskRun=Join-Path $taskRoot ('verification/chord-touch-20261028/run_'+(Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Force -Path $taskRun | Out-Null
    $taskStageFile=Join-Path $taskRun 'stage.json'
    & $Python (Join-Path $PSScriptRoot 'prepare-direct-score-verification.py') --output $taskStageFile
    if($LASTEXITCODE -ne 0){throw 'Independent snapshot failed'}
    $Stage=(Get-Content -LiteralPath $taskStageFile -Raw | ConvertFrom-Json).stage
}
$coreCases=@('stable_polar_n4','stable_polar_n64','mpr121_early_mailbox','mpr121_frontend_early',
    'touch_i2s_latency','touch_i2s_gain','touch_i2s_early_gain',
    'stable_chord_n64','stable_chord_piano','stereo_peak_limiter')
$regressionCases=@('hierarchy_board_timing','hierarchy_pixels','hierarchy_system','hierarchy_board',
    'menu_hierarchy','slider_expression','oled_idle10','slider_liveness','oled_i2c_stream',
    'oled_wave_capture','oled_idle_menu','oled_wave_display','oled_wave_board','oled_wave_board_timing',
    'oled_volume','oled_menu','oled_volume_board','slider_menu','slider_performance',
    'slider_volume_control','slider_volume_system','menu_system','menu_replay','mode_status',
    'global_panic','control_router','expression_merge','audio_boot_status','audio_i2s',
    'headroom_smoothing_n64','learning_system','mpr121_frontend','mpr121_backpressure',
    'mpr121_capacity','transport_status_equivalence','runtime_fx','mpr121_i2c','mpr121_timing',
    'audio_units','audio_engine_n4','runtime_fx_storage','performance_retrigger','event_fifo_pipeline','note_arbiter')
foreach($taskGroup in @('Core','Regression')){
    if($Group -ne 'All' -and $Group -ne $taskGroup){continue}
    $taskCases=if($taskGroup -eq 'Core'){$coreCases}else{$regressionCases}
    $taskOutput=Join-Path $Stage ('verification/chord-touch-'+$taskGroup.ToLowerInvariant())
    & (Join-Path $Stage 'scripts/test-modelsim-full.ps1') -ModelSimBin $ModelSimBin `
        -CaseName $taskCases -TimeoutSeconds 1200 -OutputRoot $taskOutput
    if($LASTEXITCODE -ne 0){throw "ModelSim $taskGroup failed; do not claim pass"}
    $taskLatest=Get-ChildItem -LiteralPath $taskOutput -Directory | Sort-Object Name | Select-Object -Last 1
    if($taskGroup -eq 'Core'){
        & $Python (Join-Path $PSScriptRoot 'analyze-chord-touch.py') `
            (Join-Path $taskLatest.FullName 'sim/audio_results') (Join-Path $taskLatest.FullName 'analysis')
        if($LASTEXITCODE -ne 0){throw 'Independent PCM/latency analysis failed'}
    }
    Write-Output "$taskGroup result: $($taskLatest.FullName)"
}
if($Build){
    & $Python (Join-Path $Stage 'scripts/build-contest-isolated.py') --variant chord-touch --without-gao `
        --baseline (Join-Path $taskRoot 'docs/reports/menu-hierarchy-20261028/selected/build-results.json') `
        --output-root (Join-Path $Stage 'verification/chord-touch-build')
    if($LASTEXITCODE -ne 0){throw 'Build/timing failed; generated bitstream is not accepted'}
}
Write-Output "Stage: $Stage"
