param([int]$HoldFrames=4096,[int]$ReleaseFrames=6000,[int[]]$VoiceCounts=@(64,1),[int]$ProbeFrames=0,[string]$SourceRoot='',
    [string]$PythonExe='C:/Users/asus/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe')
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if(!$SourceRoot) {$SourceRoot=$project}
$output=Join-Path $project ('verification/piano-headroom-20261020/realtime/run_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N').Substring(0,8))
$snapshot=Join-Path $output 'snapshot'
New-Item -ItemType Directory -Path (Join-Path $snapshot 'pcm') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $SourceRoot 'rtl') -Destination $snapshot -Recurse
New-Item -ItemType Directory -Path (Join-Path $snapshot 'sim') -Force | Out-Null
foreach($f in @('tb_main_audio_realtime.sv','modelsim_local.ini')) {Copy-Item -LiteralPath (Join-Path $project "sim/$f") -Destination (Join-Path $snapshot 'sim')}
$sources=@('rtl/i2s_tx.v','rtl/audio/voice_state_ram.v','rtl/audio/wavetable_rom.v','rtl/audio/dds_lane.v','rtl/audio/adsr.v','rtl/audio/pitch_expression.v','rtl/audio/stereo_mixer.v','rtl/audio/gain_saturator.v','rtl/audio/audio_fx.v','rtl/audio/fm_piano_lane.v','rtl/audio/polar_lane.v','rtl/audio/voice_engine.v','rtl/audio/runtime_audio_fx.v','sim/tb_main_audio_realtime.sv')
$hashes=[ordered]@{}
foreach($s in $sources) {$hashes[$s]=(Get-FileHash -LiteralPath (Join-Path $snapshot $s) -Algorithm SHA256).Hash.ToLowerInvariant()}
foreach($rom in (Get-ChildItem -LiteralPath (Join-Path $snapshot 'rtl/audio/rom') -Filter '*.hex' -File | Sort-Object Name)) {
    $hashes['rtl/audio/rom/'+$rom.Name]=(Get-FileHash -LiteralPath $rom.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
$metadata=[ordered]@{kind='isolated RTL snapshot, true 1024 clocks/frame, serialized I2S compared bit-exact to accepted PCM; no FPGA timing model';source_root=$SourceRoot;voices=$VoiceCounts;hold_frames=$HoldFrames;release_frames=$ReleaseFrames;probe_frames=$ProbeFrames;FM_ENABLE=1;AUTO_HEADROOM=1;runtime_fx=0;BCLK_HALF_DIV=8;clock_period_ns=20.345;sources=$hashes}
[IO.File]::WriteAllText((Join-Path $output 'source_hashes.json'),($metadata|ConvertTo-Json -Depth 5))
$do="onerror {quit -f -code 1}`nonbreak {resume}`nvlib work`nvlog -sv -work work $($sources -join ' ')`n"
foreach($n in $VoiceCounts) {
  $do+="vsim -onfinish stop -voptargs=+acc work.tb_main_audio_realtime -gN=$n -gHOLD_FRAMES=$HoldFrames -gRELEASE_FRAMES=$ReleaseFrames -gPROBE_FRAMES=$ProbeFrames`nrun -all`nif {[examine -radix unsigned /tb_main_audio_realtime/test_passed] != 1} {quit -f -code 1}`nquit -sim`n"
}
$do+="quit -f -code 0`n"
[IO.File]::WriteAllText((Join-Path $snapshot 'run_realtime.do'),$do)
Write-Output "MAIN_REALTIME_RUN=$output"
Push-Location $snapshot
try {& 'D:/msim/modelsim_ase/win32aloem/vsim.exe' -c -modelsimini sim/modelsim_local.ini -do run_realtime.do -l (Join-Path $output 'modelsim.log'); $status=$LASTEXITCODE}
finally {Pop-Location}
if($status -ne 0) {throw "Realtime ModelSim failed: $status"}
if($ProbeFrames -eq 0) {
    & $PythonExe (Join-Path $PSScriptRoot 'analyze-main-audio-realtime.py') --input $output
    if($LASTEXITCODE -ne 0) {throw 'Realtime serialized PCM frequency analysis failed'}
}
Write-Output "MAIN_REALTIME_PASS=$output"
