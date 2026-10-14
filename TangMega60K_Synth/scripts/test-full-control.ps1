param([string]$IcarusBin='C:\iverilog\bin')
$ErrorActionPreference='Stop'
$projectDir=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Push-Location $projectDir
try {
    New-Item -ItemType Directory -Force 'sim/full_results' | Out-Null
    $cases=@(
        @('tb_full_control','sim/tb_full_control.sv','rtl/control/remote_command_router.v'),
        @('tb_expression_merge','sim/tb_full_control.sv','rtl/control/expression_merge.v'),
        @('tb_note_arbiter','sim/tb_full_control.sv','rtl/control/note_arbiter.v'),
        @('tb_runtime_audio_fx','sim/tb_runtime_audio_fx.sv','rtl/audio/runtime_audio_fx.v'),
        @('tb_runtime_audio_fx_storage','sim/tb_runtime_audio_fx_storage.sv','rtl/audio/runtime_audio_fx.v','sim/runtime_audio_fx_reference.sv'),
        @('tb_remote_note_watchdog','sim/tb_remote_note_watchdog.sv','rtl/control/remote_note_watchdog.v'),
        @('tb_audio_visualizer','sim/tb_audio_visualizer.sv','rtl/visual/audio_visualizer.v'),
        @('tb_audio_monitor_cdc','sim/tb_audio_monitor_cdc.sv','rtl/visual/audio_monitor_cdc.v'),
        @('tb_watchdog_arbiter_integration','sim/tb_watchdog_arbiter_integration.sv','rtl/control/remote_command_router.v','rtl/control/remote_note_watchdog.v','rtl/control/note_arbiter.v','rtl/event_fifo_v2.v')
    )
    foreach($case in $cases) {
        $top=$case[0];$exe="sim/full_results/$top.vvp"
        $sources=$case[1..($case.Count-1)]
        & "$IcarusBin/iverilog.exe" -g2012 -s $top -o $exe @sources
        if($LASTEXITCODE -ne 0){throw "Compile failed: $top"}
        $output=& "$IcarusBin/vvp.exe" $exe 2>&1
        $output | Tee-Object -FilePath "sim/full_results/$top.log"
        if($LASTEXITCODE -ne 0){throw "Simulation failed: $top"}
        if(!($output -match 'PASS')){throw "Missing PASS: $top"}
    }
} finally {Pop-Location}
