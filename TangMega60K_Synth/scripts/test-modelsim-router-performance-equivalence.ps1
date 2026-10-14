param(
    [string]$ModelSimBin='D:/msim/modelsim_ase/win32aloem',
    [string]$RouterSource='',
    [int[]]$Seeds=@(471833,94177,123456789),
    [ValidateRange(1000,100000)][int]$RandomCycles=10000,
    [string]$OutputRoot=''
)
$ErrorActionPreference='Stop'
$projectDir=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if(!$RouterSource){$RouterSource=Join-Path $projectDir 'rtl/control/remote_command_router.v'}
$RouterSource=[IO.Path]::GetFullPath($RouterSource)
if(!$OutputRoot){$OutputRoot=Join-Path $projectDir 'verification/timing-20261014'}
$runDir=Join-Path $OutputRoot ('router_performance_equivalence_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $runDir|Out-Null
$runnerHash=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
$runnerSnapshot=Join-Path $runDir 'test-modelsim-router-performance-equivalence.ps1'
Copy-Item -LiteralPath $PSCommandPath -Destination $runnerSnapshot
if((Get-FileHash -LiteralPath $runnerSnapshot -Algorithm SHA256).Hash -ne $runnerHash){throw 'Runner snapshot mismatch'}
$sources=@(
    [pscustomobject]@{Label='candidate router';Source=$RouterSource},
    [pscustomobject]@{Label='shared production controller';Source=(Join-Path $projectDir 'rtl/performance/performance_controller.v')},
    [pscustomobject]@{Label='frozen router reference';Source=(Join-Path $projectDir 'sim/remote_command_router_reference.v')},
    [pscustomobject]@{Label='integration equivalence TB';Source=(Join-Path $projectDir 'sim/tb_router_performance_equivalence.sv')}
)
$inputs=@()
foreach($source in $sources){
    $target=Join-Path $runDir ([IO.Path]::GetFileName($source.Source))
    $before=(Get-FileHash -LiteralPath $source.Source -Algorithm SHA256).Hash
    Copy-Item -LiteralPath $source.Source -Destination $target
    $snapshot=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    if($snapshot -ne $before){throw "Source snapshot mismatch: $($source.Source)"}
    $inputs+=[pscustomobject]@{Label=$source.Label;Source=$source.Source;SnapshotPath=$target;Before=$before;Snapshot=$snapshot}
}
$referenceText=Get-Content -LiteralPath (Join-Path $runDir 'remote_command_router_reference.v') -Raw
$referenceSourceHash=[regex]::Match($referenceText,'Source SHA256: ([a-f0-9]{64})').Groups[1].Value
if(!$referenceSourceHash){throw 'Frozen router reference fingerprint missing'}
$work=(Join-Path $runDir 'work').Replace('\','/')
$ini=Join-Path $runDir 'modelsim.ini'
@('[Library]',"work = $work",'[vsim]')|Set-Content -LiteralPath $ini -Encoding ASCII
$compileDo=Join-Path $runDir 'compile.do'
$compilePaths=@($inputs.SnapshotPath|ForEach-Object {'{'+$_.Replace('\','/')+'}'}) -join ' '
@('onerror {quit -f -code 2}',"vlib {$work}","vlog -sv -work {$work} $compilePaths",'quit -f -code 0')|
    Set-Content -LiteralPath $compileDo -Encoding ASCII
$vsim=Join-Path $ModelSimBin 'vsim.exe'
function Invoke-ModelSim([string]$DoFile,[string]$Name){
    $log=Join-Path $runDir "$Name.log";$console=Join-Path $runDir "$Name.console.log"
    $savedPreference=$ErrorActionPreference
    try{$ErrorActionPreference='Continue';& $vsim -c -modelsimini $ini -do $DoFile -l $log *> $console;$toolExit=$LASTEXITCODE}
    finally{$ErrorActionPreference=$savedPreference}
    [pscustomobject]@{ExitCode=$toolExit;Text=((Get-Content -LiteralPath $log -Raw)+"`n"+(Get-Content -LiteralPath $console -Raw));Log=$log;Console=$console}
}
$timer=[Diagnostics.Stopwatch]::StartNew()
$compile=Invoke-ModelSim $compileDo 'compile'
if($compile.ExitCode -ne 0 -or $compile.Text -match '(?im)^\s*#?\s*\*\*\s+(Error|Fatal)(\s|:)' -or $compile.Text -match 'Errors:\s*[1-9]'){
    throw "Compilation failed: $($compile.Log)"
}
$selected=@([pscustomobject]@{Name='oracle_negative';Seed=$Seeds[0];Negative=$true})
foreach($seed in $Seeds){$selected+=[pscustomobject]@{Name="seed_$seed";Seed=$seed;Negative=$false}}
$cases=@()
foreach($case in $selected){
    $doFile=Join-Path $runDir "$($case.Name).do";$wave=(Join-Path $runDir "$($case.Name).wlf").Replace('\','/')
    $extra=if($case.Negative){' +ORACLE_NEGATIVE'}else{''}
    @('onerror {quit -f -code 2}','onbreak {quit -f -code 3}',
      "vsim -onfinish exit -wlf {$wave} work.tb_router_performance_equivalence +SEED=$($case.Seed) +RANDOM_CYCLES=$RandomCycles$extra",
      'run -all','quit -f -code 0')|Set-Content -LiteralPath $doFile -Encoding ASCII
    $result=Invoke-ModelSim $doFile $case.Name
    $hasFatal=$result.Text -match '(?im)^\s*#?\s*\*\*\s+Fatal:'
    $hasError=$result.Text -match '(?im)^\s*#?\s*\*\*\s+Error(?:\s|:)'
    $hasPass=$result.Text.Contains('ROUTER PERFORMANCE EQUIVALENCE PASS')
    # ModelSim -onfinish exit returns zero for $fatal; exact log oracle is used.
    $matched=if($case.Negative){$hasFatal -and !$hasError -and !$hasPass -and $result.Text.Contains('router/performance output mismatch cycle=10') -and
        $result.Text.Contains('Time: 96 ns') -and $result.Text.Contains('Instance: /tb_router_performance_equivalence')}
        else{$result.ExitCode -eq 0 -and !$hasFatal -and !$hasError -and $hasPass}
    $marker=[regex]::Match($result.Text,'ROUTER PERFORMANCE EQUIVALENCE PASS[^\r\n]*').Value
    $cases+=[pscustomobject]@{Name=$case.Name;Seed=$case.Seed;ExpectedFatal=$case.Negative;Matched=$matched;ExitCode=$result.ExitCode;Marker=$marker;Log=$result.Log;Console=$result.Console}
    Write-Host "$($case.Name): matched=$matched exit=$($result.ExitCode) $marker"
}
foreach($item in $inputs){
    $item|Add-Member NoteProperty After (Get-FileHash -LiteralPath $item.Source -Algorithm SHA256).Hash
    $item|Add-Member NoteProperty SnapshotAfter (Get-FileHash -LiteralPath $item.SnapshotPath -Algorithm SHA256).Hash
}
$inputsUnchanged=@($inputs|Where-Object {$_.Before -ne $_.Snapshot -or $_.Before -ne $_.After -or $_.Before -ne $_.SnapshotAfter}).Count -eq 0
$runnerAfter=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
$runnerSnapshotHash=(Get-FileHash -LiteralPath $runnerSnapshot -Algorithm SHA256).Hash
$runnerUnchanged=$runnerHash -eq $runnerAfter -and $runnerHash -eq $runnerSnapshotHash
$passed=@($cases|Where-Object {!$_.Matched}).Count -eq 0 -and $inputsUnchanged -and $runnerUnchanged
$summary=[pscustomobject]@{Passed=$passed;ReferenceSourceSHA256=$referenceSourceHash;EffectiveRouterSHA256=$inputs[0].Snapshot;
    InputsUnchanged=$inputsUnchanged;RunnerSHA256=$runnerHash;RunnerAfterSHA256=$runnerAfter;RunnerSnapshotSHA256=$runnerSnapshotHash;
    RunnerUnchanged=$runnerUnchanged;ElapsedSeconds=$timer.Elapsed.TotalSeconds;RandomCyclesPerSeed=$RandomCycles;Cases=$cases;Inputs=$inputs}
$summary|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $runDir 'summary.json') -Encoding UTF8
Write-Host "ROUTER PERFORMANCE EQUIVALENCE results: $runDir"
if(!$passed){throw 'Router/performance equivalence failed; inspect the actual logs'}
