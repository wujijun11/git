param(
    [string]$ModelSimBin='C:/modelsim/modeltech64_10.6e/win64',
    [string]$PythonExe='python',
    [string]$OutputDir='sim/eight_results'
)
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Push-Location $project
try {
    $output=[IO.Path]::GetFullPath($OutputDir)
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    & $PythonExe scripts/piano_model/refine_eight.py --model assets/audio/piano_eight_profiles.json --rom rtl/audio/rom
    if($LASTEXITCODE -ne 0) { throw 'Eight-partial ROM generation failed' }
    $stage=Join-Path ([IO.Path]::GetTempPath()) ('codex_eight_'+[guid]::NewGuid().ToString('N'))
    foreach($dir in @('sim/eight_results','sim/audio_results','sim/fm_keyboard_pcm')) {
        New-Item -ItemType Directory -Path "$stage/$dir" -Force | Out-Null
    }
    Copy-Item -LiteralPath rtl -Destination $stage -Recurse
    foreach($name in @('modelsim_local.ini','tb_eight_regions.sv','tb_audio_engine.sv','tb_audio_i2s.sv','tb_fm_keyboard.sv','run_eight_piano.do')) {
        Copy-Item -LiteralPath "sim/$name" -Destination "$stage/sim"
    }
    Write-Output "Isolated simulation: $stage"
    Push-Location $stage
    try {
        & "$ModelSimBin/vsim.exe" -c -modelsimini sim/modelsim_local.ini -do sim/run_eight_piano.do -l sim/eight_results/modelsim.log
        $simExit=$LASTEXITCODE
    } finally {
        Pop-Location
        Copy-Item "$stage/sim/eight_results/*" -Destination $output -Force
        Copy-Item "$stage/sim/fm_keyboard_pcm/*" -Destination $output -Force
    }
    if($simExit -ne 0) { throw "Eight-partial ModelSim failed: $simExit" }
    foreach($marker in @('EIGHT REGIONS PASSED','POLAR ENGINE PASSED N=4','POLAR ENGINE PASSED N=64','PIANO I2S PASSED','FM KEYBOARD PASSED: C4-C6, 25 notes','FM ENGINE PASSED N=4','FM ENGINE PASSED N=64')) {
        if(!(Select-String -LiteralPath "$output/modelsim.log" -Pattern $marker -SimpleMatch -Quiet)) { throw "Missing marker: $marker" }
    }
    & $PythonExe scripts/export-eight-piano.py --input $output --model assets/audio/piano_eight_profiles.json
    if($LASTEXITCODE -ne 0) { throw 'Eight-partial PCM analysis failed' }
    Write-Output 'EIGHT-PARTIAL PIANO VERIFICATION PASSED'
} finally { Pop-Location }
