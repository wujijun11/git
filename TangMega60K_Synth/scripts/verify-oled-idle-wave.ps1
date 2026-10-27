param(
    [string]$Python = 'python',
    [string]$ModelSimBin = 'C:/modelsim/modeltech64_10.6e/win64',
    [string]$StageParent = '',
    [switch]$Build
)
# 隔离验证：只复制/仿真/构建，不扫描或下载，不覆盖原R2位流。
$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$taskRun = Join-Path $taskRoot ('verification/oled-idle-wave/run_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $taskRun -Force | Out-Null
$taskStageFile = Join-Path $taskRun 'stage.json'
$taskArgs = @((Join-Path $PSScriptRoot 'prepare-direct-score-verification.py'), '--output', $taskStageFile)
if ($StageParent) { $taskArgs += @('--stage-parent', $StageParent) }
& $Python @taskArgs
if ($LASTEXITCODE -ne 0) { throw 'Snapshot failed' }
$taskStage = (Get-Content -LiteralPath $taskStageFile -Raw | ConvertFrom-Json).stage
$taskCases = @('oled_i2c_stream', 'oled_wave_capture', 'oled_idle_menu', 'oled_wave_display',
    'oled_wave_board', 'oled_wave_board_timing', 'oled_volume', 'oled_menu', 'oled_volume_board',
    'slider_menu', 'slider_performance', 'full_system', 'audio_i2s', 'headroom_smoothing_n64',
    'transport_status_equivalence', 'global_panic', 'audio_boot_status', 'performance_held_write',
    'performance', 'performance_retrigger', 'performance_commit', 'direct_system', 'menu_system', 'learning_system')
& (Join-Path $taskStage 'scripts/test-modelsim-full.ps1') -ModelSimBin $ModelSimBin `
    -CaseName $taskCases -TimeoutSeconds 1200 -OutputRoot (Join-Path $taskStage 'verification/oled-wave-modelsim')
if ($LASTEXITCODE -ne 0) { throw 'OLED waveform regression failed' }
$taskLatest = Get-ChildItem -LiteralPath (Join-Path $taskStage 'verification/oled-wave-modelsim') -Directory |
    Sort-Object Name | Select-Object -Last 1
& $Python (Join-Path $taskRoot 'scripts/analyze-oled-wave.py') `
    (Join-Path $taskLatest.FullName 'sim/audio_results') (Join-Path $taskRun 'analysis')
if ($LASTEXITCODE -ne 0) { throw 'External I2S/OLED pixel comparison failed' }
if ($Build) {
    & $Python (Join-Path $taskStage 'scripts/build-contest-isolated.py') --variant oled-idle-wave `
        --without-gao --baseline (Join-Path $taskRoot 'docs/reports/headroom-board-triage-20261027/selected-r2/build-results.json') `
        --output-root (Join-Path $taskStage 'verification/oled-wave-build')
    if ($LASTEXITCODE -ne 0) { throw 'Build or timing failed; do not use bitstream' }
}
Write-Output "Stage: $taskStage"
Write-Output "Run: $taskRun"
