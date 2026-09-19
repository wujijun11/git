param(
    [string]$ModelSimBin='C:\modelsim\modeltech64_10.6e\win64',
    [string]$PythonExe='python',
    [switch]$SkipBaseline
)
$ErrorActionPreference='Stop'
$projectDir=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$vsim=Join-Path $ModelSimBin 'vsim.exe'
if(!(Test-Path -LiteralPath $vsim)) { throw "ModelSim not found: $vsim" }
& $PythonExe -c 'import numpy; print("FFT dependency: numpy", numpy.__version__)'
if($LASTEXITCODE -ne 0) { throw 'Python 3 and numpy are required for FFT analysis.' }
Push-Location $projectDir
try {
    $stage=Join-Path ([IO.Path]::GetTempPath()) ('codex_live64_'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path "$stage/sim/live64_results" -Force | Out-Null
    Copy-Item -LiteralPath 'rtl' -Destination $stage -Recurse
    foreach($name in @('modelsim_local.ini','run_live64.do','tb_live64_source.sv','tb_live64_spectrum.sv','tb_audio_edgecases.sv')) {
        Copy-Item -LiteralPath "sim/$name" -Destination "$stage/sim"
    }
    Write-Host "Fresh ModelSim build: $stage"
    Push-Location $stage
    try {
        & $vsim -c -modelsimini sim/modelsim_local.ini -do sim/run_live64.do -l sim/live64_results/modelsim.log
        $simExit=$LASTEXITCODE
    } finally {
        Pop-Location
        New-Item -ItemType Directory -Path sim/live64_results -Force | Out-Null
        Copy-Item "$stage/sim/live64_results/*" -Destination sim/live64_results -Force
    }
    if($simExit -ne 0) { throw "Live64 ModelSim failed: $simExit" }
    foreach($marker in @('LIVE64 SOURCE PASSED','AUDIO EDGECASES PASSED','LIVE64 SPECTRUM CAPTURE PASSED')) {
        if(!(Select-String -LiteralPath sim/live64_results/modelsim.log -Pattern $marker -SimpleMatch -Quiet)) {
            throw "Missing completion marker: $marker"
        }
    }
    & $PythonExe scripts/analyze-live64.py --results sim/live64_results --rom rtl/audio/rom
    if($LASTEXITCODE -ne 0) { throw '64-tone FFT verification failed' }
    & $PythonExe scripts/test-live64-analysis.py
    if($LASTEXITCODE -ne 0) { throw 'FFT analyzer negative tests failed' }
    if(!$SkipBaseline) {
        & "$PSScriptRoot/test-audio.ps1" -ModelSimBin $ModelSimBin
        & "$PSScriptRoot/test.ps1" -ModelSimBin $ModelSimBin
    }
    Write-Host "LIVE64 ALL PASSED (baseline skipped: $SkipBaseline)"
} finally { Pop-Location }
