param(
    [string]$ModelSimBin='C:\modelsim\modeltech64_10.6e\win64',
    [string]$OutputDir='sim/fm_keyboard_results'
)
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Push-Location $project
try {
    $output=[IO.Path]::GetFullPath($OutputDir)
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $stage=Join-Path ([IO.Path]::GetTempPath()) ('codex_fm_keyboard_'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path "$stage/sim/fm_keyboard_pcm" -Force | Out-Null
    Copy-Item -LiteralPath rtl -Destination $stage -Recurse
    foreach($name in @('modelsim_local.ini','tb_fm_keyboard.sv','run_fm_keyboard.do')) {
        Copy-Item -LiteralPath "sim/$name" -Destination "$stage/sim"
    }
    Push-Location $stage
    try {
        & "$ModelSimBin/vsim.exe" -c -modelsimini sim/modelsim_local.ini -do sim/run_fm_keyboard.do -l sim/fm_keyboard_pcm/modelsim.log
        $simExit=$LASTEXITCODE
    } finally {
        Pop-Location
        Copy-Item "$stage/sim/fm_keyboard_pcm/*" -Destination $output -Force
    }
    if($simExit -ne 0) { throw "FM keyboard ModelSim failed: $simExit" }
    if(!(Select-String -LiteralPath "$output/modelsim.log" -Pattern 'FM KEYBOARD PASSED: C4-C6, 25 notes' -SimpleMatch -Quiet)) {
        throw 'Missing FM keyboard completion marker'
    }
    $csv=@(Get-ChildItem -LiteralPath $output -Filter 'note_*.csv' -File)
    if($csv.Count -ne 25) { throw "Expected 25 note CSV files, found $($csv.Count)" }
    Write-Output "FM KEYBOARD HDL VERIFICATION PASSED: 25 notes; PCM at $output"
} finally { Pop-Location }
