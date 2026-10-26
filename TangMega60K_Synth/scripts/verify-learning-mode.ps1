param(
    [string]$Python = '',
    [string]$ModelSimBin = 'C:/modelsim/modeltech64_10.6e/win64',
    [string]$Gowin = 'C:/Gowin/Gowin_V1.9.12_x64/IDE/bin/gw_sh.exe',
    [switch]$Build
)
# 独立英文路径避免ModelSim 10.6中文路径问题。只验证，不访问硬件。
$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (!$Python) { $Python = Join-Path $taskRoot 'tmp/desktop-python/Scripts/python.exe' }
$taskRun = Join-Path $taskRoot ('verification/learning-mode/run_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $taskRun -Force | Out-Null
$taskManifest = Join-Path $taskRun 'stage.json'
& $Python (Join-Path $PSScriptRoot 'prepare-direct-score-verification.py') --output $taskManifest
if ($LASTEXITCODE -ne 0) { throw 'Could not create verification snapshot' }
$taskStage = (Get-Content -LiteralPath $taskManifest -Raw | ConvertFrom-Json).stage
$taskCases = @('learning_mode','learning_status','learning_system','performance','performance_retrigger',
    'performance_commit','direct_score','direct_capability','direct_system','mode_status',
    'control_router','menu_system','menu_replay','global_panic','ws2812_matrix',
    'score_capacity_1024','performance_stage','full_system','mpr121_backpressure')
try {
    & (Join-Path $taskStage 'scripts/test-modelsim-full.ps1') -ModelSimBin $ModelSimBin `
        -CaseName $taskCases -OutputRoot (Join-Path $taskStage 'verification/modelsim')
    if ($LASTEXITCODE -ne 0) { throw 'ModelSim regression failed' }
    if ($Build) {
        & $Python (Join-Path $taskStage 'scripts/build-contest-isolated.py') --variant learning-mode `
            --without-gao --gowin $Gowin --baseline (Join-Path $taskStage 'verification/baseline.json') `
            --output-root (Join-Path $taskStage 'verification/build')
        if ($LASTEXITCODE -ne 0) { throw 'Build or timing failed; candidate must not be delivered as accepted' }
    }
} finally {
    # 成功/失败证据均保留，不删除临时现场，也不改原full/impl。
    if (Test-Path -LiteralPath (Join-Path $taskStage 'verification/modelsim')) {
        Copy-Item -LiteralPath (Join-Path $taskStage 'verification/modelsim') -Destination $taskRun -Recurse
    }
    Write-Output "完整验证现场：$taskStage"
    Write-Output "本地日志副本：$taskRun"
}
