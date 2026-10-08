$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    & C:/iverilog/bin/iverilog.exe -g2012 -s tb_poly16_event_source `
        -o sim/poly16_event_source_test.vvp `
        rtl/diagnostics/poly16_event_source.v sim/tb_poly16_event_source.sv
    if ($LASTEXITCODE -ne 0) { throw 'Poly16 event source compilation failed' }
    & C:/iverilog/bin/vvp.exe sim/poly16_event_source_test.vvp
    if ($LASTEXITCODE -ne 0) { throw 'Poly16 event source simulation failed' }
} finally { Pop-Location }
