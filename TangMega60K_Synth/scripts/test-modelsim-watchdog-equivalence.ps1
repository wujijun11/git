param(
    [string]$ModelSimBin='D:/msim/modelsim_ase/win32aloem',
    [switch]$Baseline,
    [int[]]$Seeds=@(734921,94177,123456789),
    [ValidateRange(1000,1000000)][int]$RandomCycles=20000,
    [string]$OutputRoot=''
)
$ErrorActionPreference='Stop'
$projectDir=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if(!$OutputRoot){$OutputRoot=Join-Path $projectDir 'verification/timing-20261014'}
$runDir=Join-Path $OutputRoot ('watchdog_equivalence_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $runDir | Out-Null
$runnerHashBefore=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
$runnerSnapshot=Join-Path $runDir 'test-modelsim-watchdog-equivalence.ps1'
Copy-Item -LiteralPath $PSCommandPath -Destination $runnerSnapshot
if((Get-FileHash -LiteralPath $runnerSnapshot -Algorithm SHA256).Hash -ne $runnerHashBefore){throw 'Runner changed while creating snapshot'}
$sourcePaths=@('rtl/control/remote_note_watchdog.v','sim/remote_note_watchdog_reference.v','sim/tb_remote_watchdog_equivalence.sv')
$inputs=@()
foreach($relative in $sourcePaths){
    $source=Join-Path $projectDir $relative
    $target=Join-Path $runDir ([IO.Path]::GetFileName($source))
    $beforeCopyHash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    Copy-Item -LiteralPath $source -Destination $target
    $snapshotHash=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    if($snapshotHash -ne $beforeCopyHash){throw "Source changed while creating snapshot: $relative"}
    $inputs+= [pscustomobject]@{Path=$relative;CurrentBefore=$beforeCopyHash;Snapshot=$snapshotHash}
}
if($Baseline){
    # Recreate the original production module from the frozen reference, so a
    # baseline remains reproducible while the live production source changes.
    $reference=Get-Content -LiteralPath (Join-Path $runDir 'remote_note_watchdog_reference.v') -Raw
    $baselineText=($reference -replace '^// Frozen[^\r\n]*\r?\n','').Replace('module remote_note_watchdog_reference #(','module remote_note_watchdog #(')
    [IO.File]::WriteAllText((Join-Path $runDir 'remote_note_watchdog.v'),$baselineText,[Text.UTF8Encoding]::new($false))
}
$referenceText=Get-Content -LiteralPath (Join-Path $runDir 'remote_note_watchdog_reference.v') -Raw
$frozenSourceHash=[regex]::Match($referenceText,'Source SHA256: ([a-f0-9]{64})').Groups[1].Value
if(!$frozenSourceHash){throw 'Frozen reference source fingerprint missing'}
$effectiveDutHash=(Get-FileHash -LiteralPath (Join-Path $runDir 'remote_note_watchdog.v') -Algorithm SHA256).Hash.ToLowerInvariant()
if($Baseline -and $effectiveDutHash -ne $frozenSourceHash){throw 'Recreated baseline differs from frozen original source'}
$work=(Join-Path $runDir 'work').Replace('\','/')
$ini=Join-Path $runDir 'modelsim.ini'
@('[Library]',"work = $work",'[vsim]')|Set-Content -LiteralPath $ini -Encoding ASCII
$compileDo=Join-Path $runDir 'compile.do'
$rtl=(Join-Path $runDir 'remote_note_watchdog.v').Replace('\','/')
$ref=(Join-Path $runDir 'remote_note_watchdog_reference.v').Replace('\','/')
$bench=(Join-Path $runDir 'tb_remote_watchdog_equivalence.sv').Replace('\','/')
$compileDefines=if($Baseline){'+define+WATCHDOG_BASELINE'}else{''}
@('onerror {quit -f -code 2}',"vlib {$work}","vlog -sv $compileDefines -work {$work} {$rtl} {$ref} {$bench}",'quit -f -code 0')|
    Set-Content -LiteralPath $compileDo -Encoding ASCII
$vsim=Join-Path $ModelSimBin 'vsim.exe'
function Invoke-ModelSim([string]$DoFile,[string]$LogName){
    $console=Join-Path $runDir "$LogName.console.log"
    $log=Join-Path $runDir "$LogName.log"
    $savedPreference=$ErrorActionPreference
    try{
        $ErrorActionPreference='Continue'
        & $vsim -c -modelsimini $ini -do $DoFile -l $log *> $console
        $exitCode=$LASTEXITCODE
    }finally{$ErrorActionPreference=$savedPreference}
    $body=(Get-Content -LiteralPath $log -Raw)+"`n"+(Get-Content -LiteralPath $console -Raw)
    [pscustomobject]@{ExitCode=$exitCode;Text=$body;Log=$log;Console=$console}
}
$timer=[Diagnostics.Stopwatch]::StartNew()
$compile=Invoke-ModelSim $compileDo 'compile'
if($compile.ExitCode -ne 0 -or $compile.Text -match '(?im)^\s*#?\s*\*\*\s+(Error|Fatal)(\s|:)' -or $compile.Text -match 'Errors:\s*[1-9]'){
    throw "Compilation failed: $($compile.Log)"
}
$cases=@()
$selected=@([pscustomobject]@{Name='oracle_negative';Seed=$Seeds[0];Negative=$true})
foreach($seed in $Seeds){$selected+=[pscustomobject]@{Name="seed_$seed";Seed=$seed;Negative=$false}}
foreach($case in $selected){
    $doFile=Join-Path $runDir "$($case.Name).do"
    $wave=(Join-Path $runDir "$($case.Name).wlf").Replace('\','/')
    $extra=if($case.Negative){' +ORACLE_NEGATIVE'}else{''}
    @('onerror {quit -f -code 2}','onbreak {quit -f -code 3}',
      "vsim -onfinish exit -wlf {$wave} work.tb_remote_watchdog_equivalence +SEED=$($case.Seed) +RANDOM_CYCLES=$RandomCycles$extra",
      'run -all','quit -f -code 0')|Set-Content -LiteralPath $doFile -Encoding ASCII
    $result=Invoke-ModelSim $doFile $case.Name
    $fatal=$result.Text -match '(?im)^\s*#?\s*\*\*\s+Fatal:'
    $hasError=$result.Text -match '(?im)^\s*#?\s*\*\*\s+Error(?:\s|:)'
    $pass=$result.Text.Contains('WATCHDOG EQUIVALENCE PASS')
    # -onfinish exit in ModelSim 2020.1 may return zero for $fatal. Logs and an
    # exact terminal marker are authoritative for both positive/negative runs.
    $matched=if($case.Negative){
        $fatal -and !$hasError -and !$pass -and $result.Text.Contains('output mismatch cycle=10') -and
        $result.Text.Contains('Time: 96 ns') -and $result.Text.Contains('Instance: /tb_remote_watchdog_equivalence')
    }else{$result.ExitCode -eq 0 -and !$fatal -and !$hasError -and $pass}
    $marker=[regex]::Match($result.Text,'WATCHDOG EQUIVALENCE PASS[^\r\n]*').Value
    $cases+=[pscustomobject]@{Name=$case.Name;Seed=$case.Seed;ExpectedFatal=$case.Negative;Matched=$matched;ExitCode=$result.ExitCode;Marker=$marker;Log=$result.Log;Console=$result.Console}
    Write-Host "$($case.Name): matched=$matched exit=$($result.ExitCode) $marker"
}
foreach($item in $inputs){
    $item|Add-Member NoteProperty CurrentAfter (Get-FileHash -LiteralPath (Join-Path $projectDir $item.Path) -Algorithm SHA256).Hash
    $item|Add-Member NoteProperty SnapshotAfter (Get-FileHash -LiteralPath (Join-Path $runDir ([IO.Path]::GetFileName($item.Path))) -Algorithm SHA256).Hash
    # Baseline only: production DUT is deliberately reconstructed from the
    # frozen reference after the original source copy was verified above.
    $expectedSnapshot=if($Baseline -and $item.Path -eq 'rtl/control/remote_note_watchdog.v'){$frozenSourceHash}else{$item.CurrentBefore}
    $item|Add-Member NoteProperty ExpectedSnapshot $expectedSnapshot
    $item|Add-Member NoteProperty SnapshotMatches ($item.SnapshotAfter -eq $expectedSnapshot)
}
$inputsUnchanged=@($inputs|Where-Object {$_.CurrentBefore -ne $_.CurrentAfter}).Count -eq 0
$snapshotsUnchanged=@($inputs|Where-Object {!$_.SnapshotMatches}).Count -eq 0
$runnerHashAfter=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
$runnerSnapshotHash=(Get-FileHash -LiteralPath $runnerSnapshot -Algorithm SHA256).Hash
$runnerUnchanged=$runnerHashBefore -eq $runnerHashAfter -and $runnerHashBefore -eq $runnerSnapshotHash
$passed=@($cases|Where-Object {!$_.Matched}).Count -eq 0 -and $inputsUnchanged -and $snapshotsUnchanged -and $runnerUnchanged
$summary=[pscustomobject]@{Passed=$passed;Baseline=[bool]$Baseline;ReferenceSourceSHA256=$frozenSourceHash;EffectiveDutSHA256=$effectiveDutHash;InputsUnchanged=$inputsUnchanged;SnapshotsUnchanged=$snapshotsUnchanged;RunnerSHA256=$runnerHashBefore;RunnerAfterSHA256=$runnerHashAfter;RunnerSnapshotSHA256=$runnerSnapshotHash;RunnerUnchanged=$runnerUnchanged;ElapsedSeconds=$timer.Elapsed.TotalSeconds;RandomCyclesPerSeed=$RandomCycles;Cases=$cases;Inputs=$inputs}
$summary|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $runDir 'summary.json') -Encoding UTF8
Write-Host "WATCHDOG EQUIVALENCE results: $runDir"
if(!$passed){throw 'Watchdog equivalence failed; inspect exact logs before claiming acceptance'}
