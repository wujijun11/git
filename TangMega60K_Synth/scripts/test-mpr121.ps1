param([string]$Iverilog = 'iverilog', [string]$Vvp = 'vvp')
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskOutput = Join-Path $taskRoot 'sim/mpr121-tests'
New-Item -ItemType Directory -Path $taskOutput -Force | Out-Null
$taskRtl = @('i2c_register_master.v','mpr121_sampler.v','mpr121_key_eventizer.v','mpr121_slider.v','mpr121_input_frontend.v') | ForEach-Object { Join-Path $taskRoot "rtl/sensors/$_" }
$taskLog = [System.Collections.Generic.List[string]]::new()
foreach ($taskTop in @('tb_mpr121_i2c','tb_mpr121_frontend','tb_mpr121_backpressure','tb_mpr121_timing','tb_mpr121_eventizer_capacity')) {
    $taskBinary = Join-Path $taskOutput "$taskTop.vvp"
    $taskBench = Join-Path $taskRoot "sim/$taskTop.sv"
    $taskModel = Join-Path $taskRoot 'sim/tb_mpr121_model.sv'
    & $Iverilog -g2012 -s $taskTop -o $taskBinary @taskRtl $taskModel $taskBench
    if ($LASTEXITCODE -ne 0) { throw "Compilation failed: $taskTop" }
    $taskLines = & $Vvp $taskBinary 2>&1
    $taskLines | ForEach-Object { Write-Output $_; $taskLog.Add([string]$_) }
    if ($LASTEXITCODE -ne 0) { throw "Simulation failed: $taskTop" }
    if (-not ($taskLines -match "PASS $taskTop")) { throw "Missing PASS: $taskTop" }
}
$taskLog | Set-Content -LiteralPath (Join-Path $taskRoot 'sim/test_mpr121_results.log') -Encoding utf8
