param([switch]$ShortOnly)
$ErrorActionPreference='Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    New-Item -ItemType Directory -Force 'sim/mono_diagnostic_results' | Out-Null
    [xml]$projectXml=Get-Content -LiteralPath 'mono_diag/MonoDiagnostic.gprj'
    $projectDir=Join-Path (Get-Location).Path 'mono_diag'
    $sources=@($projectXml.Project.FileList.File |
        Where-Object type -eq 'file.verilog' |
        ForEach-Object { [IO.Path]::GetFullPath((Join-Path $projectDir $_.path)) })
    & C:/iverilog/bin/iverilog.exe -g2012 -DSIM -s tb_mono_diag_contract `
        -o sim/mono_diagnostic_results/contract.vvp @sources sim/tb_mono_diag_contract.sv
    if($LASTEXITCODE -ne 0) { throw 'Diagnostic contract simulation compilation failed' }
    & C:/iverilog/bin/vvp.exe sim/mono_diagnostic_results/contract.vvp |
        Tee-Object -FilePath sim/mono_diagnostic_results/contract.log
    if($LASTEXITCODE -ne 0) { throw 'Diagnostic contract simulation failed' }
    $testName=if($ShortOnly) { 'protocol' } else { 'test' }
    $shortParameter=if($ShortOnly) { '-Ptb_mono_diagnostic.SHORT=1' } else { '-Ptb_mono_diagnostic.SHORT=0' }
    & C:/iverilog/bin/iverilog.exe -g2012 -DSIM -s tb_mono_diagnostic $shortParameter `
        -o "sim/mono_diagnostic_results/$testName.vvp" @sources sim/tb_mono_diagnostic.sv
    if($LASTEXITCODE -ne 0) { throw 'Mono diagnostic simulation compilation failed' }
    & C:/iverilog/bin/vvp.exe "sim/mono_diagnostic_results/$testName.vvp" |
        Tee-Object -FilePath "sim/mono_diagnostic_results/$testName.log"
    if($LASTEXITCODE -ne 0) { throw 'Mono diagnostic simulation failed' }
    if(!(Select-String -LiteralPath "sim/mono_diagnostic_results/$testName.log" -SimpleMatch -Quiet `
        -Pattern 'MONO DIAGNOSTIC PASSED')) { throw 'Missing diagnostic completion marker' }
    if(!$ShortOnly) {
        $python='C:/Users/asus/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe'
        & $python scripts/check-mono-diagnostic.py
        if($LASTEXITCODE -ne 0) { throw 'Mono diagnostic PCM spectral validation failed' }
    }
} finally { Pop-Location }
