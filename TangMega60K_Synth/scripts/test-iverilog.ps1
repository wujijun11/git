param([string]$IcarusBin = 'C:\iverilog\bin')
$ErrorActionPreference = 'Stop'
$projectDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$simDir = Join-Path $projectDir 'sim'
$outputDir = Join-Path $simDir 'iverilog_results'
$compiler = Join-Path $IcarusBin 'iverilog.exe'
$runtime = Join-Path $IcarusBin 'vvp.exe'
foreach ($tool in @($compiler, $runtime)) {
    if (!(Test-Path -LiteralPath $tool)) { throw "Simulator tool not found: $tool" }
}
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$v1 = @('voice_allocator', 'captain_control_top', 'i2s_tx', 'captain_system_top')
$v2 = @('voice_allocator_v2', 'expression_controls_v2', 'captain_control_top_v2', 'i2s_tx', 'captain_system_top_v2')
$cases = @(
    @{ Name='allocator'; Top='tb_voice_allocator'; RTL=$v1; Define=@(); Marker='ALL TESTS PASSED' },
    @{ Name='i2s'; Top='tb_i2s_tx'; RTL=$v1; Define=@(); Marker='ALL I2S TESTS PASSED' },
    @{ Name='tone'; Top='tb_tone_demo'; RTL=@('i2s_tx','test_tone_source','tone_demo_top'); Define=@(); Marker='ALL TONE TESTS PASSED' },
    @{ Name='control_v2'; Top='tb_control_v2'; RTL=$v2; Define=@(); Marker='ALL V2 CONTROL TESTS PASSED' },
    @{ Name='i2s_v2'; Top='tb_i2s_tx'; RTL=$v2; Define=@('-DV2_INTERFACE_TEST'); Marker='ALL V2 I2S TESTS PASSED' },
    @{ Name='legacy_v2'; Top='tb_voice_allocator'; RTL=$v2; Define=@('-DV2_LEGACY_TEST'); Marker='ALL V2 LEGACY TESTS PASSED' }
)
Push-Location $outputDir
try {
    foreach ($case in $cases) {
        $binary = Join-Path $outputDir ($case.Name + '.vvp')
        $log = Join-Path $outputDir ($case.Name + '.log')
        $rtlFiles = @($case.RTL | ForEach-Object { Join-Path $projectDir ('rtl/' + $_ + '.v') })
        $testbench = Join-Path $simDir ($case.Top + '.sv')
        $compileArgs = @('-g2012','-s',$case.Top,'-o',$binary) + $case.Define + $rtlFiles + @($testbench)
        & $compiler @compileArgs
        if ($LASTEXITCODE -ne 0) { throw "Compilation failed: $($case.Name)" }
        & $runtime $binary > $log
        $runExit = $LASTEXITCODE
        Get-Content -LiteralPath $log
        if ($runExit -ne 0) { throw "Simulation failed: $($case.Name)" }
        if (!(Select-String -LiteralPath $log -SimpleMatch $case.Marker -Quiet)) {
            throw "Missing success marker: $($case.Name)"
        }
    }
} finally { Pop-Location }
