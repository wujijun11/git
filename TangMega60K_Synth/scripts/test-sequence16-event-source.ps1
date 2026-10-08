$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    & C:/iverilog/bin/iverilog.exe -g2012 -s tb_sequence16_event_source `
        -o sim/sequence16_event_source_test.vvp `
        rtl/diagnostics/sequence16_event_source.v sim/tb_sequence16_event_source.sv
    if ($LASTEXITCODE -ne 0) { throw 'Sequence16 event source compilation failed' }
    & C:/iverilog/bin/vvp.exe sim/sequence16_event_source_test.vvp
    if ($LASTEXITCODE -ne 0) { throw 'Sequence16 event source simulation failed' }
} finally { Pop-Location }
