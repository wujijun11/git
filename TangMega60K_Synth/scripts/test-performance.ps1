$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    & C:/iverilog/bin/iverilog.exe -g2012 -s tb_performance_controller `
        -o sim/performance_controller_test.vvp `
        rtl/performance/performance_controller.v sim/tb_performance_controller.sv
    if ($LASTEXITCODE -ne 0) { throw 'Performance controller compilation failed' }
    & C:/iverilog/bin/vvp.exe sim/performance_controller_test.vvp
    if ($LASTEXITCODE -ne 0) { throw 'Performance controller simulation failed' }
    & C:/iverilog/bin/iverilog.exe -g2012 -s tb_performance_retrigger `
        -o sim/performance_retrigger_test.vvp `
        rtl/performance/performance_controller.v rtl/voice_allocator_v2.v sim/tb_performance_retrigger.sv
    if ($LASTEXITCODE -ne 0) { throw 'Performance retrigger compilation failed' }
    & C:/iverilog/bin/vvp.exe sim/performance_retrigger_test.vvp
    if ($LASTEXITCODE -ne 0) { throw 'Performance retrigger simulation failed' }
    & C:/iverilog/bin/iverilog.exe -g2012 -s tb_performance_commit_pipeline `
        -o sim/performance_commit_pipeline_test.vvp `
        rtl/performance/performance_controller.v sim/tb_performance_commit_pipeline.sv
    if ($LASTEXITCODE -ne 0) { throw 'Performance commit pipeline compilation failed' }
    & C:/iverilog/bin/vvp.exe sim/performance_commit_pipeline_test.vvp
    if ($LASTEXITCODE -ne 0) { throw 'Performance commit pipeline simulation failed' }
    & C:/iverilog/bin/iverilog.exe -g2012 -s tb_board_local_actions `
        -o sim/board_local_actions_test.vvp `
        rtl/board/board_contest_full_top.v rtl/performance/performance_controller.v sim/tb_board_local_actions.sv
    if ($LASTEXITCODE -ne 0) { throw 'Board local actions compilation failed' }
    & C:/iverilog/bin/vvp.exe sim/board_local_actions_test.vvp
    if ($LASTEXITCODE -ne 0) { throw 'Board local actions simulation failed' }
    & C:/iverilog/bin/iverilog.exe -g2012 -s tb_performance_ws2812 `
        -o sim/performance_ws2812_test.vvp `
        rtl/performance/ws2812_guide.v sim/tb_performance_ws2812.sv
    if ($LASTEXITCODE -ne 0) { throw 'WS2812 guide compilation failed' }
    & C:/iverilog/bin/vvp.exe sim/performance_ws2812_test.vvp
    if ($LASTEXITCODE -ne 0) { throw 'WS2812 guide simulation failed' }
} finally { Pop-Location }
