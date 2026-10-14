$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    & C:/iverilog/bin/iverilog.exe -g2012 -s tb_ws2812_matrix `
        -o sim/ws2812_matrix_test.vvp `
        rtl/performance/ws2812_guide.v sim/tb_ws2812_matrix.sv
    if ($LASTEXITCODE -ne 0) { throw 'WS2812 matrix compilation failed' }
    & C:/iverilog/bin/vvp.exe sim/ws2812_matrix_test.vvp
    if ($LASTEXITCODE -ne 0) { throw 'WS2812 matrix simulation failed' }
    foreach ($testTop in @('tb_ws2812_invalid_zero_count', 'tb_ws2812_invalid_large_count', 'tb_ws2812_invalid_key_map', 'tb_ws2812_duplicate_key_map')) {
        $testImage = "sim/$testTop.vvp"
        & C:/iverilog/bin/iverilog.exe -g2012 -s $testTop -o $testImage `
            rtl/performance/ws2812_guide.v sim/tb_ws2812_matrix.sv
        if ($LASTEXITCODE -ne 0) { throw "Invalid-parameter test compilation failed: $testTop" }
        $testOutput = & C:/iverilog/bin/vvp.exe $testImage 2>&1
        $testExit = $LASTEXITCODE
        if ($testExit -eq 0 -or ($testOutput -join "`n") -match 'PARAMETER_NOT_REJECTED') {
            throw "WS2812 invalid parameter was not rejected: $testTop"
        }
        if (($testOutput -join "`n") -notmatch 'FATAL:.*ws2812_guide') {
            throw "Unexpected error instead of DUT parameter rejection: $testTop`n$testOutput"
        }
        Write-Host "PASS WS2812 parameter rejection: $testTop"
    }
} finally { Pop-Location }
