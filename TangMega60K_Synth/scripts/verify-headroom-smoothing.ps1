param(
    [string]$Python='python',
    [string]$ModelSimBin='C:/modelsim/modeltech64_10.6e/win64',
    [string]$StageParent='',
    [switch]$Build
)
# 原滑条音量38项+余量4项，共42项。只仿真/隔离构建，不扫描或下载。
$ErrorActionPreference='Stop'
$taskRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$taskRun=Join-Path $taskRoot ('verification/headroom-smoothing/run_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $taskRun -Force | Out-Null
$taskStageJson=Join-Path $taskRun 'stage.json'
$taskArguments=@((Join-Path $PSScriptRoot 'prepare-direct-score-verification.py'),'--output',$taskStageJson)
if($StageParent){$taskArguments+=@('--stage-parent',$StageParent)}
& $Python @taskArguments
if($LASTEXITCODE -ne 0){throw 'Source snapshot failed'}
$taskStage=(Get-Content -LiteralPath $taskStageJson -Raw | ConvertFrom-Json).stage
$taskCases=@('headroom_smoother','headroom_smoothing_n4','headroom_smoothing_n64','headroom_legacy',
    'slider_volume_control','slider_performance','slider_volume_system','oled_volume','oled_volume_board',
    'slider_menu','oled_menu','oled_board','oled_board_timing','mode_status','expression_merge',
    'event_fifo_pipeline','transport_status_equivalence',
    'polar_margin_s1','polar_margin_s2','polar_margin_s3','polar_margin_negative','polar_margin_early_write',
    'touch_i2s_latency','oled_timing_regression','menu_system','learning_mode','learning_status','learning_system',
    'direct_score','direct_system','performance','performance_retrigger','performance_commit','global_panic',
    'mpr121_backpressure','mpr121_capacity','audio_i2s','full_system','menu_replay','score_capacity_1024',
    'remote_note_watchdog','watchdog_arbiter')
try {
    & (Join-Path $taskStage 'scripts/test-modelsim-full.ps1') -ModelSimBin $ModelSimBin `
        -TimeoutSeconds 1200 -CaseName $taskCases -OutputRoot (Join-Path $taskStage 'verification/modelsim-headroom')
    if($LASTEXITCODE -ne 0){throw '42-case headroom regression failed'}
    $taskLatest=Get-ChildItem -LiteralPath (Join-Path $taskStage 'verification/modelsim-headroom') -Directory |
        Sort-Object Name | Select-Object -Last 1
    foreach($taskVoiceCount in @(4,64)) {
        & $Python (Join-Path $taskRoot 'scripts/analyze-headroom-smoothing.py') `
            (Join-Path $taskLatest.FullName "sim/audio_results/headroom_smoothing_n$taskVoiceCount.csv") `
            (Join-Path $taskRun "analysis-n$taskVoiceCount")
        if($LASTEXITCODE -ne 0){throw 'PCM arithmetic/scale analysis failed'}
    }
    if($Build){
        & $Python (Join-Path $taskStage 'scripts/build-contest-isolated.py') --variant headroom-smooth `
            --without-gao --baseline (Join-Path $taskRoot 'docs/reports/slider-volume-20261026/selected-r2/build-results.json') `
            --output-root (Join-Path $taskStage 'verification/build')
        if($LASTEXITCODE -ne 0){throw 'Build or timing failed; do not use this bitstream'}
    }
} finally {
    Write-Output "Snapshot: $taskStage"
    Write-Output "Input record: $taskStageJson"
    Write-Output "Run record: $taskRun"
}
