$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
Push-Location $projectRoot
try {
    [xml]$projectXml=Get-Content -LiteralPath 'boardkeys48/BoardInstrumentB48kI2S.gprj'
    $projectDir=Join-Path $projectRoot 'boardkeys48'
    $sources=@($projectXml.Project.FileList.File |
        Where-Object { $_.type -eq 'file.verilog' -and $_.enable -ne '0' } |
        ForEach-Object { [IO.Path]::GetFullPath((Join-Path $projectDir $_.path)) })
    $vendorModel='C:/Gowin/Gowin_V1.9.12_x64/IDE/simlib/gw5a/prim_sim.v'
    & C:/iverilog/bin/iverilog.exe -g2012 -DSIM -s tb_board_key_latency `
        -o sim/key_latency_test.vvp @sources $vendorModel sim/tb_board_key_latency.sv
    if($LASTEXITCODE -ne 0) { throw 'Production board key latency compilation failed' }
    & C:/iverilog/bin/vvp.exe sim/key_latency_test.vvp |
        Tee-Object -FilePath sim/key_latency_results.log
    if($LASTEXITCODE -ne 0) { throw 'Production board key latency simulation failed' }
} finally { Pop-Location }
