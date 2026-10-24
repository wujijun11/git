param(
    [string]$ModelSimBin = 'D:/msim/modelsim_ase/win32aloem',
    [string]$PythonExe = 'C:/Users/asus/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe',
    [string]$OutputRoot = 'verification/piano-headroom-20261020/keyboard',
    [int]$HoldFrames = 16384,
    [int]$ReleaseFrames = 6000
)
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (![IO.Path]::IsPathRooted($OutputRoot)) { $OutputRoot = Join-Path $project $OutputRoot }
$output = Join-Path $OutputRoot ('run_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [guid]::NewGuid().ToString('N').Substring(0,8))
$snapshot = Join-Path $output 'snapshot'
New-Item -ItemType Directory -Path (Join-Path $snapshot 'sim/fm_keyboard_pcm') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $project 'rtl') -Destination $snapshot -Recurse
foreach ($name in @('tb_fm_keyboard.sv','modelsim_local.ini')) {
    Copy-Item -LiteralPath (Join-Path $project "sim/$name") -Destination (Join-Path $snapshot 'sim')
}
$sources = @('rtl/voice_allocator_v2.v','rtl/expression_controls_v2.v',
    'rtl/captain_control_top_v2.v','rtl/captain_system_top_v2.v','rtl/i2s_tx.v',
    'rtl/audio/voice_state_ram.v','rtl/audio/wavetable_rom.v','rtl/audio/dds_lane.v',
    'rtl/audio/adsr.v','rtl/audio/pitch_expression.v','rtl/audio/stereo_mixer.v',
    'rtl/audio/gain_saturator.v','rtl/audio/audio_fx.v','rtl/audio/fm_piano_lane.v',
    'rtl/audio/polar_lane.v','rtl/audio/voice_engine.v','sim/tb_fm_keyboard.sv')
$hashes = [ordered]@{}
foreach ($source in $sources) {
    $hashes[$source] = (Get-FileHash -LiteralPath (Join-Path $snapshot $source) -Algorithm SHA256).Hash.ToLowerInvariant()
}
foreach ($rom in (Get-ChildItem -LiteralPath (Join-Path $snapshot 'rtl/audio/rom') -Filter '*.hex' -File | Sort-Object Name)) {
    $hashes['rtl/audio/rom/' + $rom.Name] = (Get-FileHash -LiteralPath $rom.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
$metadata = [ordered]@{kind='ModelSim isolated RTL snapshot; not DAC measurements';
    timbre=2; auto_headroom=1; hold_frames=$HoldFrames; release_frames=$ReleaseFrames;
    voice_count=4; notes='MIDI 60..84'; sources=$hashes}
[IO.File]::WriteAllText((Join-Path $output 'source_hashes.json'), ($metadata | ConvertTo-Json -Depth 5))
$do = @"
onerror {quit -f -code 1}
onbreak {resume}
vlib work
vlog -sv -work work $($sources -join ' ')
vsim -onfinish stop -voptargs=+acc work.tb_fm_keyboard -gTIMBRE=2 -gAUTO_HEADROOM=1 -gHOLD_FRAMES=$HoldFrames -gRELEASE_FRAMES=$ReleaseFrames
run -all
if {[examine -radix unsigned /tb_fm_keyboard/test_passed] != 1} {quit -f -code 1}
quit -f -code 0
"@
$doPath = Join-Path $snapshot 'run_keyboard.do'
[IO.File]::WriteAllText($doPath, $do)
Write-Output "PIANO_HEADROOM_RUN=$output"
Push-Location $snapshot
try {
    & (Join-Path $ModelSimBin 'vsim.exe') -c -modelsimini sim/modelsim_local.ini -do run_keyboard.do -l (Join-Path $output 'modelsim.log')
    $simExit = $LASTEXITCODE
} finally {
    Pop-Location
    $pcm = Join-Path $output 'pcm'
    New-Item -ItemType Directory -Path $pcm -Force | Out-Null
    Copy-Item -Path (Join-Path $snapshot 'sim/fm_keyboard_pcm/*.csv') -Destination $pcm -Force -ErrorAction SilentlyContinue
}
if ($simExit -ne 0) { throw "ModelSim keyboard simulation failed: $simExit" }
if (!(Select-String -LiteralPath (Join-Path $output 'modelsim.log') -SimpleMatch 'FM KEYBOARD PASSED: C4-C6, 25 notes, 50 events, 25 releases' -Quiet)) {
    throw 'Missing complete 25-key completion marker'
}
& $PythonExe (Join-Path $PSScriptRoot 'analyze-piano-headroom.py') --input $output --hold-frames $HoldFrames --release-frames $ReleaseFrames
if ($LASTEXITCODE -ne 0) { throw '25-key PCM analysis failed' }
Write-Output "PIANO HEADROOM KEYBOARD PASSED: $output"
