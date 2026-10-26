param(
    [string]$Python='python',
    [string]$ModelSimBin='C:/modelsim/modeltech64_10.6e/win64',
    [string]$Gowin='C:/Gowin/Gowin_V1.9.12_x64/IDE/bin/gw_sh.exe',
    [string]$StageParent='',
    [string]$BaselineReport='',
    [switch]$Build
)
# 滑条音量独立测试入口。不访问USB/BLE，不调用Programmer，不覆盖原full/impl。
$ErrorActionPreference='Stop'
$taskRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$taskRun=Join-Path $taskRoot ('verification/slider-volume/run_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $taskRun -Force | Out-Null
$taskStageJson=Join-Path $taskRun 'stage.json'
$taskArguments=@((Join-Path $PSScriptRoot 'prepare-direct-score-verification.py'),'--output',$taskStageJson)
if($StageParent){$taskArguments+=@('--stage-parent',$StageParent)}
& $Python @taskArguments
if($LASTEXITCODE -ne 0){throw 'Source snapshot failed'}
$taskStage=(Get-Content -LiteralPath $taskStageJson -Raw | ConvertFrom-Json).stage
if(!$BaselineReport){
    $BaselineReport=Join-Path $taskRoot 'delivery-pipeline-round2/evidence/fpga/build-results.json'
    if(!(Test-Path -LiteralPath $BaselineReport)){
        $BaselineReport=Join-Path $taskRoot 'verification/slider-volume-baseline.json'
    }
}
if($Build){
    if(!(Test-Path -LiteralPath $BaselineReport)){throw 'Missing actual baseline report'}
    New-Item -ItemType Directory -Path (Join-Path $taskStage 'verification') -Force | Out-Null
    Copy-Item -LiteralPath $BaselineReport -Destination (Join-Path $taskStage 'verification/slider-volume-baseline.json')
}
try{
    & (Join-Path $taskStage 'scripts/test-modelsim-full.ps1') -ModelSimBin $ModelSimBin -TimeoutSeconds 1200 `
        -CaseName @('slider_volume_control','slider_performance','slider_volume_system','oled_volume','oled_volume_board',
            'slider_menu','oled_menu','oled_board','oled_board_timing','mode_status','expression_merge',
            'event_fifo_pipeline','transport_status_equivalence',
            'polar_margin_s1','polar_margin_s2','polar_margin_s3','polar_margin_negative','polar_margin_early_write',
            'touch_i2s_latency','oled_timing_regression','menu_system','learning_mode','learning_status','learning_system',
            'direct_score','direct_system','performance','performance_retrigger','performance_commit','global_panic',
            'mpr121_backpressure','mpr121_capacity','audio_i2s','full_system','menu_replay','score_capacity_1024',
            'remote_note_watchdog','watchdog_arbiter') `
        -OutputRoot (Join-Path $taskStage 'verification/modelsim-volume')
    if($LASTEXITCODE -ne 0){throw '38-case ModelSim regression failed'}
    $taskLatest=Get-ChildItem -LiteralPath (Join-Path $taskStage 'verification/modelsim-volume') -Directory |
        Sort-Object Name | Select-Object -Last 1
    & $Python (Join-Path $taskStage 'scripts/analyze-touch-i2s-latency.py') `
        (Join-Path $taskLatest.FullName 'sim/audio_results/touch_i2s_latency.csv') (Join-Path $taskRun 'analysis')
    if($LASTEXITCODE -ne 0){throw 'Latency evidence check failed'}
    if($Build){
        & $Python (Join-Path $taskStage 'scripts/build-contest-isolated.py') --variant slider-volume-final `
            --without-gao --gowin $Gowin --baseline (Join-Path $taskStage 'verification/slider-volume-baseline.json') `
            --output-root (Join-Path $taskStage 'verification/build')
        if($LASTEXITCODE -ne 0){throw 'Gowin build/timing rejected; no accepted bitstream'}
    }
}finally{
    Write-Output "隔离现场：$taskStage"
    Write-Output "输入清单：$taskStageJson"
    Write-Output "本轮记录：$taskRun"
}
