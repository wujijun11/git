param([string]$IcarusBin='C:\iverilog\bin',[string]$VendorModel='C:\Gowin\Gowin_V1.9.12_x64\IDE\simlib\gw5a\prim_sim.v')
$ErrorActionPreference='Stop'
$projectDir=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$outputDir=Join-Path $projectDir 'sim/video_results'
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$cases=@(
    @{Name='encoder';RTL=@('video_tmds_encoder.v');Vendor=$false},
    @{Name='timing';RTL=@('video_timing_640x480.v');Vendor=$false},
    @{Name='vendor';RTL=@('video_clocking.v','video_tmds_encoder.v','video_tmds_tx.v');Vendor=$true}
)
foreach($case in $cases){
    $binary=Join-Path $outputDir ($case.Name+'.vvp')
    $sources=@($case.RTL|ForEach-Object{Join-Path $projectDir ('rtl/visual/'+$_)})
    if($case.Vendor){if(!(Test-Path -LiteralPath $VendorModel)){throw 'Gowin GW5A primitive model not found'};$sources+=@($VendorModel)}
    & (Join-Path $IcarusBin 'iverilog.exe') -g2012 -DSIM -s ('tb_video_'+$case.Name) -o $binary @sources (Join-Path $projectDir ('sim/tb_video_'+$case.Name+'.sv'))
    if($LASTEXITCODE -ne 0){throw "Video compile failed: $($case.Name)"}
    & (Join-Path $IcarusBin 'vvp.exe') $binary | Tee-Object -FilePath (Join-Path $outputDir ($case.Name+'.log'))
    if($LASTEXITCODE -ne 0){throw "Video test failed: $($case.Name)"}
}
