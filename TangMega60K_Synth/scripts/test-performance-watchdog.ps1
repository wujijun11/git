$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    & C:/iverilog/bin/iverilog.exe -g2012 -s tb_watchdog_arbiter_integration `
        -o sim/watchdog_arbiter_integration_test.vvp `
        rtl/control/remote_command_router.v rtl/control/remote_note_watchdog.v `
        rtl/control/note_arbiter.v rtl/event_fifo_v2.v sim/tb_watchdog_arbiter_integration.sv
    if ($LASTEXITCODE -ne 0) { throw 'Watchdog/arbiter integration compilation failed' }
    & C:/iverilog/bin/vvp.exe sim/watchdog_arbiter_integration_test.vvp
    if ($LASTEXITCODE -ne 0) { throw 'Watchdog/arbiter integration simulation failed' }
} finally { Pop-Location }
