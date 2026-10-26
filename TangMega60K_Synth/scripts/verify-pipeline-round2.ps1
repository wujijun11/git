param(
    [string]$Python = 'python',
    [string]$ModelSimBin = 'C:/modelsim/modeltech64_10.6e/win64',
    [string]$Gowin = 'C:/Gowin/Gowin_V1.9.12_x64/IDE/bin/gw_sh.exe',
    [string]$StageParent = '',
    [string]$BaselineReport = '',
    [switch]$Build
)
# 仅仿真与隔离构建：不调用下载器，不接触USB/串口/BLE，不改变原full/impl。
$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$taskRunName = 'run_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [guid]::NewGuid().ToString('N').Substring(0,8)
$taskRun = Join-Path $taskRoot ('verification/pipeline-round2/' + $taskRunName)
New-Item -ItemType Directory -Path $taskRun -Force | Out-Null
$taskStageJson = Join-Path $taskRun 'stage.json'
$taskStageArguments = @((Join-Path $PSScriptRoot 'prepare-direct-score-verification.py'), '--output', $taskStageJson)
if ($StageParent) { $taskStageArguments += @('--stage-parent', $StageParent) }
& $Python @taskStageArguments
if ($LASTEXITCODE -ne 0) { throw '冻结源码失败，未启动EDA工具' }
$taskStage = (Get-Content -LiteralPath $taskStageJson -Raw | ConvertFrom-Json).stage
if (!$BaselineReport) {
    $BaselineReport = Join-Path $taskRoot 'delivery-timing-latency/evidence/fpga/build-results.json'
    if (!(Test-Path -LiteralPath $BaselineReport)) {
        $BaselineReport = Join-Path $taskRoot 'verification/pipeline-round2-baseline.json'
    }
}
if ($Build) {
    if (!(Test-Path -LiteralPath $BaselineReport)) { throw '缺少上一测试版的实际构建报告' }
    New-Item -ItemType Directory -Path (Join-Path $taskStage 'verification') -Force | Out-Null
    Copy-Item -LiteralPath $BaselineReport -Destination (Join-Path $taskStage 'verification/pipeline-round2-baseline.json')
}
try {
    & (Join-Path $taskStage 'scripts/test-modelsim-full.ps1') -ModelSimBin $ModelSimBin -TimeoutSeconds 1200 `
        -CaseName @('note_event_pipeline','score_upload_tracker','event_fifo_pipeline','transport_status_equivalence',
            'polar_margin_s1','polar_margin_s2','polar_margin_s3','polar_margin_negative','polar_margin_early_write',
            'touch_i2s_latency','oled_timing_regression','menu_system','learning_mode','learning_status',
            'learning_system','direct_score','direct_system','performance','performance_retrigger',
            'performance_commit','global_panic','mpr121_backpressure','mpr121_capacity','audio_i2s',
            'full_system','menu_replay','score_capacity_1024','remote_note_watchdog','watchdog_arbiter') `
        -OutputRoot (Join-Path $taskStage 'verification/modelsim-pipeline-round2')
    if ($LASTEXITCODE -ne 0) { throw '29项ModelSim检查未全部通过' }
    $taskLatest = Get-ChildItem -LiteralPath (Join-Path $taskStage 'verification/modelsim-pipeline-round2') -Directory |
        Sort-Object Name | Select-Object -Last 1
    & $Python (Join-Path $taskStage 'scripts/analyze-touch-i2s-latency.py') `
        (Join-Path $taskLatest.FullName 'sim/audio_results/touch_i2s_latency.csv') (Join-Path $taskRun 'analysis')
    if ($LASTEXITCODE -ne 0) { throw '触摸数字通路CSV校验失败' }
    if ($Build) {
        & $Python (Join-Path $taskStage 'scripts/build-contest-isolated.py') --variant pipeline-round2-final `
            --without-gao --gowin $Gowin --baseline (Join-Path $taskStage 'verification/pipeline-round2-baseline.json') `
            --output-root (Join-Path $taskStage 'verification/build')
        if ($LASTEXITCODE -ne 0) { throw 'Gowin构建或实际时序检查未通过，不能交付位流' }
    }
} finally {
    Write-Output "隔离现场：$taskStage"
    Write-Output "输入清单：$taskStageJson"
    Write-Output "记录目录：$taskRun"
}
