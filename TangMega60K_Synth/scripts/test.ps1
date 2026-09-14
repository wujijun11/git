param([string]$ModelSimBin = 'C:\msim\modelsim_ase\win32aloem')
$ErrorActionPreference = 'Stop'
$simDir = Join-Path $PSScriptRoot '..\sim'
$simExe = Join-Path $ModelSimBin 'vsim.exe'
if (!(Test-Path -LiteralPath $simExe)) { throw "ModelSim not found: $simExe" }
Push-Location $simDir
try {
    $testCases = @(
        @{ Script = 'run.do'; Log = 'test_results.log'; Marker = 'ALL TESTS PASSED' },
        @{ Script = 'run_i2s.do'; Log = 'test_i2s_results.log'; Marker = 'ALL I2S TESTS PASSED' }
    )
    foreach ($testCase in $testCases) {
        # A new transcript cannot accidentally reuse an old success marker.
        if (Test-Path -LiteralPath $testCase.Log) { Remove-Item -LiteralPath $testCase.Log }
        & $simExe -c -modelsimini modelsim_local.ini -do $testCase.Script -l $testCase.Log
        if ($LASTEXITCODE -ne 0) { throw "ModelSim failed (exit $LASTEXITCODE). See sim/$($testCase.Log)" }
        if (!(Select-String -LiteralPath $testCase.Log -SimpleMatch $testCase.Marker -Quiet)) {
            throw "Simulation did not reach the success marker: $($testCase.Script)"
        }
    }
} finally { Pop-Location }
