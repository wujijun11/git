param([string]$GowinExe='C:/Gowin/Gowin_V1.9.12_x64/IDE/bin/gw_sh.exe',
      [string]$OutputDir='sim/eight_synthesis')
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Push-Location $project
try {
    $output=[IO.Path]::GetFullPath($OutputDir)
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $stage=Join-Path ([IO.Path]::GetTempPath()) ('codex_eight_syn_'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path "$stage/scripts" -Force | Out-Null
    Copy-Item -LiteralPath rtl -Destination $stage -Recurse
    Copy-Item -LiteralPath AudioEngine_V2.gprj -Destination $stage
    Copy-Item -LiteralPath scripts/synth-audio-fm.tcl -Destination "$stage/scripts"
    Push-Location $stage
    try {
        & $GowinExe scripts/synth-audio-fm.tcl
        $synthExit=$LASTEXITCODE
    } finally { Pop-Location }
    Get-ChildItem "$stage/impl/gwsynthesis" -File | Copy-Item -Destination $output
    if($synthExit -ne 0) { throw "Gowin synthesis failed: $synthExit" }
    Write-Output "SYNTHESIS ONLY completed: $output (place/route and board tests pending)"
} finally { Pop-Location }
