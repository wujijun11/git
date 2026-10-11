param([string]$IcarusBin='C:\iverilog\bin')
$ErrorActionPreference='Stop'
$projectDir=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Push-Location $projectDir
try {
    New-Item -ItemType Directory -Force sim/panic_results | Out-Null
    $sources=Get-ChildItem rtl -Recurse -File | Where-Object Extension -in '.v','.sv' | Select-Object -ExpandProperty FullName
    & "$IcarusBin/iverilog.exe" -g2012 -s tb_global_panic -o sim/panic_results/global_panic.vvp sim/tb_global_panic.sv $sources
    if($LASTEXITCODE -ne 0){throw 'Global PANIC compile failed'}
    & "$IcarusBin/vvp.exe" sim/panic_results/global_panic.vvp | Tee-Object -FilePath sim/panic_results/global_panic.log
    if($LASTEXITCODE -ne 0){throw 'Global PANIC simulation failed'}
    if(!(Select-String sim/panic_results/global_panic.log -Pattern 'GLOBAL PANIC PASS' -Quiet)){throw 'Missing global PANIC PASS'}
} finally {Pop-Location}
