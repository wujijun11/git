$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    & C:/iverilog/bin/iverilog.exe -g2012 -s tb_board_key_event_adapter `
        -o sim/board_key_event_adapter_test.vvp `
        rtl/board/board_key_event_adapter.v sim/tb_board_key_event_adapter.sv
    if ($LASTEXITCODE -ne 0) { throw 'Board key event adapter compilation failed' }
    & C:/iverilog/bin/vvp.exe sim/board_key_event_adapter_test.vvp
    if ($LASTEXITCODE -ne 0) { throw 'Board key event adapter simulation failed' }
} finally { Pop-Location }
