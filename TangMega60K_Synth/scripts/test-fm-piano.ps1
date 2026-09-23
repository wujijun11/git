param(
    [string]$ModelSimBin='C:\modelsim\modeltech64_10.6e\win64',
    [string]$OutputDir='sim/fm_results'
)
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Push-Location $project
try {
    $output=[IO.Path]::GetFullPath($OutputDir)
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $stage=Join-Path ([IO.Path]::GetTempPath()) ('codex_fm_'+[guid]::NewGuid().ToString('N'))
    foreach($dir in @('sim/audio_results','sim/listen_results','sim/fm_results')) {
        New-Item -ItemType Directory -Path "$stage/$dir" -Force | Out-Null
    }
    Copy-Item -LiteralPath rtl -Destination $stage -Recurse
    foreach($name in @('modelsim_local.ini','tb_audio_engine.sv','tb_audio_listen.sv','tb_audio_i2s.sv','run_fm_piano.do')) {
        Copy-Item -LiteralPath "sim/$name" -Destination "$stage/sim"
    }
    Push-Location $stage
    try {
        & "$ModelSimBin/vsim.exe" -c -modelsimini sim/modelsim_local.ini -do sim/run_fm_piano.do -l sim/fm_results/modelsim.log
        $simExit=$LASTEXITCODE
    } finally {
        Pop-Location
        Copy-Item "$stage/sim/fm_results/*" -Destination $output -Force
        Copy-Item "$stage/sim/listen_results/*" -Destination $output -Force
    }
    if($simExit -ne 0) { throw "FM ModelSim failed: $simExit" }
    foreach($marker in @('FM ENGINE PASSED N=4','FM ENGINE PASSED N=64','FM LISTEN PASSED','FM I2S PASSED')) {
        if(!(Select-String -LiteralPath "$output/modelsim.log" -Pattern $marker -SimpleMatch -Quiet)) { throw "Missing marker: $marker" }
    }
    Write-Output 'FM HDL VERIFICATION PASSED'
} finally { Pop-Location }
