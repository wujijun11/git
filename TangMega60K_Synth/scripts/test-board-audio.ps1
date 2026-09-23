$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    [xml]$projectXml = Get-Content BoardAudioDiagnostic.gprj
    $sources = @($projectXml.Project.FileList.File | Where-Object type -eq 'file.verilog' | ForEach-Object path)
    & C:/iverilog/bin/iverilog.exe -g2012 -s tb_board_audio -o sim/board_audio_test.vvp @sources sim/tb_board_audio.sv
    if ($LASTEXITCODE -ne 0) { throw 'Board audio compilation failed' }
    & C:/iverilog/bin/vvp.exe sim/board_audio_test.vvp
    if ($LASTEXITCODE -ne 0) { throw 'Board audio simulation failed' }
} finally { Pop-Location }
