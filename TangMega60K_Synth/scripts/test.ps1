param([string]$ModelSimBin = 'C:\msim\modelsim_ase\win32aloem')
$ErrorActionPreference = 'Stop'
$simDir = Join-Path $PSScriptRoot '..\sim'
$simIni = [IO.Path]::GetFullPath((Join-Path $simDir 'modelsim_local.ini'))
$simExe = Join-Path $ModelSimBin 'vsim.exe'
if (!(Test-Path -LiteralPath $simExe)) { throw "ModelSim not found: $simExe" }
Push-Location $simDir
try {
    $testCases = @(
        @{ Script = 'run.do'; Log = 'test_results.log'; Marker = 'ALL TESTS PASSED' },
        @{ Script = 'run_i2s.do'; Log = 'test_i2s_results.log'; Marker = 'ALL I2S TESTS PASSED' },
        @{ Script = 'run_interaction.do'; Log = 'test_interaction_results.log'; Marker = 'ALL INTERACTION TESTS PASSED' },
        @{ Script = 'run_tone.do'; Log = 'test_tone_results.log'; Marker = 'ALL TONE TESTS PASSED' },
        @{ Script = 'run_v2.do'; Log = 'test_v2_results.log'; Marker = 'ALL V2 CONTROL TESTS PASSED' },
        @{ Script = 'run_i2s_v2.do'; Log = 'test_i2s_v2_results.log'; Marker = 'ALL V2 I2S TESTS PASSED' },
        @{ Script = 'run_legacy_v2.do'; Log = 'test_legacy_v2_results.log'; Marker = 'ALL V2 LEGACY TESTS PASSED' },
        @{ Script = 'run_interaction_v2.do'; Log = 'test_interaction_v2_results.log'; Marker = 'ALL V2 INTERACTION TESTS PASSED' },
        @{ Script = 'run_instrument_v2.do'; Log = 'test_instrument_v2_results.log'; Marker = 'ALL INSTRUMENT V2 INTEGRATION TESTS PASSED' }
    )
    foreach ($testCase in $testCases) {
        # A new transcript cannot accidentally reuse an old success marker.
        if (Test-Path -LiteralPath $testCase.Log) { Remove-Item -LiteralPath $testCase.Log }
        & $simExe -c -modelsimini $simIni -do $testCase.Script -l $testCase.Log
        if ($LASTEXITCODE -ne 0) { throw "ModelSim failed (exit $LASTEXITCODE). See sim/$($testCase.Log)" }
        if (!(Select-String -LiteralPath $testCase.Log -SimpleMatch $testCase.Marker -Quiet)) {
            throw "Simulation did not reach the success marker: $($testCase.Script)"
        }
        if ($testCase.Script -eq 'run_instrument_v2.do') {
            foreach ($timbre in @(0,2,3)) {
                $marker = "ALL INSTRUMENT V2 INTEGRATION TESTS PASSED timbre=$timbre"
                if (!(Select-String -LiteralPath $testCase.Log -SimpleMatch $marker -Quiet)) {
                    throw "Missing integration timbre result: $timbre"
                }
            }
        }
    }
} finally { Pop-Location }
