param([string]$IcarusBin = 'C:/iverilog/bin')
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$out = Join-Path $project 'sim/b_merge_results'
New-Item -ItemType Directory -Force $out | Out-Null
$compiler = Join-Path $IcarusBin 'iverilog.exe'
$runtime = Join-Path $IcarusBin 'vvp.exe'
$v2 = @('rtl/event_fifo_v2.v','rtl/interaction_top_v2.v',
    'rtl/voice_allocator_v2.v','rtl/expression_controls_v2.v','rtl/captain_control_top_v2.v')
[xml]$audioProject = Get-Content (Join-Path $project 'AudioEngine_V2.gprj')
$audio = @($audioProject.Project.FileList.File | Where-Object type -eq 'file.verilog' | ForEach-Object { $_.path })
$cases = @(
    @{Name='interaction';Top='tb_interaction';Sources=@('rtl/event_fifo.v','rtl/interaction_top.v');Params=@();Marker='ALL INTERACTION TESTS PASSED'},
    @{Name='interaction_v2';Top='tb_interaction_v2';Sources=$v2;Params=@();Marker='ALL V2 INTERACTION TESTS PASSED'}
)
foreach ($timbre in @(0,2,3)) {
    $cases += @{Name="instrument_timbre$timbre";Top='tb_instrument_system_v2';Sources=$audio;
        Params=@("-Ptb_instrument_system_v2.TIMBRE=$timbre");Marker="ALL INSTRUMENT V2 INTEGRATION TESTS PASSED timbre=$timbre"}
}
Push-Location $project
try {
    foreach ($case in $cases) {
        $binary = Join-Path $out "$($case.Name).vvp"
        $compileLog = Join-Path $out "$($case.Name).compile.log"
        $runLog = Join-Path $out "$($case.Name).log"
        & $compiler -g2012 -s $case.Top -o $binary @($case.Params) @($case.Sources) "sim/$($case.Top).sv" > $compileLog 2>&1
        if ($LASTEXITCODE -ne 0) { Get-Content $compileLog; throw "Compilation failed: $($case.Name)" }
        & $runtime $binary > $runLog 2>&1
        $runExit = $LASTEXITCODE
        Get-Content $runLog
        if ($runExit -ne 0 -or !(Select-String -LiteralPath $runLog -SimpleMatch $case.Marker -Quiet)) {
            throw "Simulation failed or missing pass marker: $($case.Name)"
        }
    }
    Write-Output 'ALL B MERGE TESTS PASSED'
} finally { Pop-Location }
