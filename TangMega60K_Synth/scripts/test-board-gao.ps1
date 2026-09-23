$ErrorActionPreference='Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    [xml]$projectXml=Get-Content BoardAudioGAO.gprj
    $sources=@($projectXml.Project.FileList.File | Where-Object type -eq 'file.verilog' | ForEach-Object path)
    & C:/iverilog/bin/iverilog.exe -g2012 -s tb_board_gao -o sim/board_gao_test.vvp @sources sim/tb_board_gao.sv
    if($LASTEXITCODE -ne 0) { throw 'GAO board simulation compilation failed' }
    & C:/iverilog/bin/vvp.exe sim/board_gao_test.vvp
    if($LASTEXITCODE -ne 0) { throw 'GAO board simulation failed' }
} finally { Pop-Location }
