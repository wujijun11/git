param([string]$IcarusBin='C:\iverilog\bin')
$ErrorActionPreference='Stop'
$projectDir=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Push-Location $projectDir
try {
    New-Item -ItemType Directory -Force sim/full_results | Out-Null
    $sources=Get-ChildItem rtl -Recurse -File | Where-Object Extension -in '.v','.sv' | Select-Object -ExpandProperty FullName
    foreach($case in @(@('tb_instrument_full_system','FULL SYSTEM PASS'),@('tb_global_panic','GLOBAL PANIC PASS'))) {
        $top=$case[0];$binary="sim/full_results/$top.vvp";$log="sim/full_results/$top.log"
        & "$IcarusBin/iverilog.exe" -g2012 -s $top -o $binary "sim/$top.sv" $sources
        if($LASTEXITCODE -ne 0){throw "Full system compile failed: $top"}
        & "$IcarusBin/vvp.exe" $binary | Tee-Object -FilePath $log
        if($LASTEXITCODE -ne 0){throw "Full system simulation failed: $top"}
        if(!(Select-String $log -Pattern $case[1] -Quiet)){throw "Missing PASS: $top"}
    }
} finally {Pop-Location}
