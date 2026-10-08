$ErrorActionPreference='Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    $romDir='boardkeys48/rtl/audio/rom'
    New-Item -ItemType Directory -Path $romDir -Force | Out-Null
    foreach($rom in @('waves.hex','midi.hex','velocity.hex','sine.hex','ratio.hex',
                      'piano.hex','polar_lane0.hex','polar_lane1.hex','polar_ratios.hex')) {
        Copy-Item -LiteralPath "rtl/audio/rom/$rom" -Destination "$romDir/$rom" -Force
    }
    [xml]$projectXml=Get-Content boardkeys48/BoardInstrumentB48kI2S.gprj
    $projectDir=Join-Path (Get-Location).Path 'boardkeys48'
    $sources=@($projectXml.Project.FileList.File |
        Where-Object type -eq 'file.verilog' |
        ForEach-Object { [IO.Path]::GetFullPath((Join-Path $projectDir $_.path)) })
    $vendorModel='C:/Gowin/Gowin_V1.9.12_x64/IDE/simlib/gw5a/prim_sim.v'
    & C:/iverilog/bin/iverilog.exe -g2012 -DSIM -s tb_board_instrument_b_48k_i2s `
        -o sim/board_instrument_b_48k_i2s_test.vvp @sources $vendorModel sim/tb_board_instrument_b_48k_i2s.sv
    if($LASTEXITCODE -ne 0) { throw 'B 48 kHz external I2S compilation failed' }
    & C:/iverilog/bin/vvp.exe sim/board_instrument_b_48k_i2s_test.vvp |
        Tee-Object -FilePath sim/test_board_instrument_b_48k_i2s_results.log
    if($LASTEXITCODE -ne 0) { throw 'B 48 kHz external I2S simulation failed' }
} finally { Pop-Location }
