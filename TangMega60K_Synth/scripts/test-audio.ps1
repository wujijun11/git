param([string]$ModelSimBin='C:\modelsim\modeltech64_10.6e\win64')
$ErrorActionPreference='Stop'
$projectDir=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$vsim=Join-Path $ModelSimBin 'vsim.exe'
if (!(Test-Path -LiteralPath $vsim)) { throw "ModelSim not found: $vsim" }
Push-Location $projectDir
$stageDir=$null
try {
    & "$PSScriptRoot/generate-audio-roms.ps1"
    New-Item -ItemType Directory -Force 'sim/audio_results' | Out-Null
    # A fresh temp build prevents stale compiled libraries passing. The .do
    # uses explicit paths because this host's old Tcl glob enumeration fails.
    $stageDir=Join-Path ([IO.Path]::GetTempPath()) ('codex_audio_'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stageDir | Out-Null
    Copy-Item -LiteralPath 'rtl' -Destination $stageDir -Recurse
    New-Item -ItemType Directory -Path "$stageDir/sim/audio_results" -Force | Out-Null
    Get-ChildItem 'sim' -File | Where-Object { $_.Name -match '^(tb_audio.*\.sv|run_audio\.do|modelsim_local\.ini)$' } |
        Copy-Item -Destination "$stageDir/sim"
    Write-Host "ModelSim isolated build: $stageDir"
    Push-Location $stageDir
    try {
        & $vsim -c -modelsimini sim/modelsim_local.ini -do sim/run_audio.do -l sim/audio_results/modelsim.log
        $simExit=$LASTEXITCODE
    } finally {
        Pop-Location
        Copy-Item "$stageDir/sim/audio_results/*" -Destination 'sim/audio_results' -Force
    }
    if($simExit -ne 0) { throw "Audio simulation failed: $simExit" }
    foreach($marker in @('AUDIO ENGINE PASSED N=4','AUDIO ENGINE PASSED N=64',
        'AUDIO DSP UNITS PASSED','AUDIO I2S INTEGRATION PASSED')) {
        if(!(Select-String -LiteralPath sim/audio_results/modelsim.log -Pattern $marker -SimpleMatch -Quiet)) {
            throw "Missing result marker: $marker"
        }
    }
    Write-Host 'Verified every audio test completion marker.'
    & "$PSScriptRoot/verify-audio-samples.ps1"
    Write-Host 'ALL AUDIO TESTS PASSED (ModelSim and exported PCM checks).'
} finally { Pop-Location }
