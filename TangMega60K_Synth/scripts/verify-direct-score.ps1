param(
    [string]$Python = '',
    [string]$ModelSimBin = 'C:/modelsim/modeltech64_10.6e/win64',
    [string]$Gowin = 'C:/Gowin/Gowin_V1.9.12_x64/IDE/bin/gw_sh.exe',
    [switch]$Build
)
# 创建隔离快照，只仿真/构建；从不扫描或下载板卡，不修改原full/impl。
$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (!$Python) { $Python = Join-Path $taskRoot 'tmp/desktop-python/Scripts/python.exe' }
$taskRun = Join-Path $taskRoot ('verification/direct-score/run_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $taskRun -Force | Out-Null
$taskManifest = Join-Path $taskRun 'stage.json'
& $Python (Join-Path $PSScriptRoot 'prepare-direct-score-verification.py') --output $taskManifest
if ($LASTEXITCODE -ne 0) { throw 'Could not create verification snapshot' }
$taskStage = (Get-Content -LiteralPath $taskManifest -Raw | ConvertFrom-Json).stage
$taskCases = @('direct_score','direct_capability','direct_system','performance_stage','score_capacity_1024',
    'menu_system','menu_replay','mode_status','control_router','performance',
    'performance_retrigger','performance_commit','full_system','global_panic')
& (Join-Path $taskStage 'scripts/test-modelsim-full.ps1') -ModelSimBin $ModelSimBin `
    -CaseName $taskCases -OutputRoot (Join-Path $taskStage 'verification/modelsim')
if ($LASTEXITCODE -ne 0) { throw 'ModelSim regression failed; preserve stage for diagnostics' }
if ($Build) {
    if (!(Test-Path -LiteralPath (Join-Path $taskStage 'verification/baseline.json'))) {
        throw 'Build comparison needs verification/direct-score/baseline.json from the delivery evidence'
    }
    & $Python (Join-Path $taskStage 'scripts/build-contest-isolated.py') --variant direct-score `
        --without-gao --gowin $Gowin --baseline (Join-Path $taskStage 'verification/baseline.json') `
        --output-root (Join-Path $taskStage 'verification/build')
    if ($LASTEXITCODE -ne 0) { throw 'Gowin build or timing failed; do not use the candidate bitstream' }
}
Write-Output "原工程与实现保留。完整日志和构建在：$taskStage"
Write-Output "输入清单在：$taskManifest"
