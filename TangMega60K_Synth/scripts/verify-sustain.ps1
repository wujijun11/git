param(
    [string]$Python='python',
    [string]$ModelSimBin='C:/modelsim/modeltech64_10.6e/win64',
    [string]$Stage='',
    [ValidateSet('Core','Regression','All')][string]$Group='All',
    [switch]$Build
)
# 每次使用英文冻结目录；原最终版、旧实验版和板卡都不被此脚本操作。
$ErrorActionPreference='Stop'
$projectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if(!$Stage){
    $metadata=Join-Path $projectRoot ('verification/sustain/stage_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'.json')
    & $Python (Join-Path $PSScriptRoot 'prepare-direct-score-verification.py') --output $metadata
    if($LASTEXITCODE -ne 0){throw '延音快照创建失败'}
    $Stage=(Get-Content -LiteralPath $metadata -Raw | ConvertFrom-Json).stage
}
$groups=[ordered]@{
    Core=@('sustain_remote_timeout','sustain_gate_n4','sustain_gate_n64','sustain_allocator_n4','sustain_allocator_n64',
        'sustain_router','sustain_menu','sustain_system','sustain_full64',
        'sustain_neutral_n4','sustain_neutral_n64')
    Regression=@('stable_polar_n4','stable_polar_n64','stable_chord_n64','stable_chord_piano',
        'audio_units','audio_i2s','full_system','menu_hierarchy','hierarchy_pixels','hierarchy_system',
        'hierarchy_board','hierarchy_board_timing','slider_expression','oled_idle10','oled_i2c_stream',
        'global_panic','learning_system','remote_uart','mpr121_frontend_early','touch_i2s_early_gain',
        'runtime_fx','mode_status','direct_capability','learning_status')
}
foreach($name in $groups.Keys){
    if($Group -ne 'All' -and $Group -ne $name){continue}
    & (Join-Path $Stage 'scripts/test-modelsim-full.ps1') -ModelSimBin $ModelSimBin `
        -CaseName $groups[$name] -TimeoutSeconds 1200 `
        -OutputRoot (Join-Path $Stage ('verification/sustain-'+$name.ToLowerInvariant()))
    if($LASTEXITCODE -ne 0){throw "延音 $name 仿真失败"}
}
if($Build){
    & $Python (Join-Path $Stage 'scripts/build-contest-isolated.py') --variant sustain --without-gao `
        --baseline (Join-Path $projectRoot 'docs/reports/chord-touch-20261028/selected/build-results.json') `
        --output-root (Join-Path $Stage 'verification/sustain-build')
    if($LASTEXITCODE -ne 0){throw '延音完整构建/时序未通过'}
}
Write-Output "延音冻结目录：$Stage"
