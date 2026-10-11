param([string]$IcarusBin = 'C:\iverilog\bin')
$ErrorActionPreference = 'Stop'
$projectDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$outputDir = Join-Path $projectDir 'sim/remote_results'
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$binary = Join-Path $outputDir 'uart.vvp'
& (Join-Path $IcarusBin 'iverilog.exe') -g2012 -Wall -s tb_remote_uart_transport -o $binary (Join-Path $projectDir 'rtl/remote/remote_uart_transport.sv') (Join-Path $projectDir 'sim/tb_remote_uart_transport.sv')
if ($LASTEXITCODE -ne 0) { throw 'UART compilation failed' }
& (Join-Path $IcarusBin 'vvp.exe') $binary | Tee-Object -FilePath (Join-Path $outputDir 'uart.log')
if ($LASTEXITCODE -ne 0) { throw 'UART test failed' }
