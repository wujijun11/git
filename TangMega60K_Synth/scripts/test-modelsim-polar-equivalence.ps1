param(
    [string]$CandidateRoot='',
    [string]$ModelSimBin='D:/msim/modelsim_ase/win32aloem',
    [int[]]$Seeds=@(471833,94177,123456789),
    [ValidateRange(1000,10000)][int]$RandomTransactions=1000,
    [string]$OutputRoot=''
)
$ErrorActionPreference='Stop'
# A .cmd launched from PowerShell 7 can inherit its PSModulePath. Load the
# matching Windows PowerShell utility module explicitly for Get-FileHash/JSON.
if($PSVersionTable.PSEdition -eq 'Desktop'){
    Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1') -Force
}
$projectDir=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if(!$CandidateRoot){$CandidateRoot=$projectDir}
$CandidateRoot=[IO.Path]::GetFullPath($CandidateRoot)
if(!$OutputRoot){$OutputRoot=Join-Path $projectDir 'verification/hold-margin-20261014'}
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
if(!$Seeds.Count -or @($Seeds|Select-Object -Unique).Count -ne $Seeds.Count){throw 'Seeds must be a nonempty unique list'}

# Keep all simulation files local to a fresh run. Do not modify shared ModelSim
# libraries/ini, production sources, ROMs or the historical accepted evidence.
$resolvedBin=$null
foreach($bin in @($ModelSimBin,'C:/msim/modelsim_ase/win32aloem','C:/modelsim/modeltech64_10.6e/win64')|Select-Object -Unique){
    if((Test-Path -LiteralPath (Join-Path $bin 'vsim.exe')) -and
       (Test-Path -LiteralPath (Join-Path $bin 'vlog.exe')) -and
       (Test-Path -LiteralPath (Join-Path $bin 'vlib.exe'))){$resolvedBin=[IO.Path]::GetFullPath($bin);break}
}
if(!$resolvedBin){throw 'A complete ModelSim installation was not found'}
$runDir=Join-Path $OutputRoot ('polar_equivalence_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $runDir|Out-Null
$snapshot=Join-Path $runDir 'source_snapshot'
New-Item -ItemType Directory -Path $snapshot|Out-Null
$sources=@(
    [pscustomobject]@{Label='candidate production polar lane';Source=(Join-Path $CandidateRoot 'rtl/audio/polar_lane.v');Relative='candidate/rtl/audio/polar_lane.v'},
    [pscustomobject]@{Label='frozen accepted polar lane reference';Source=(Join-Path $projectDir 'sim/polar_lane_reference.v');Relative='test/polar_lane_reference.v'},
    [pscustomobject]@{Label='cycle and memory equivalence testbench';Source=(Join-Path $projectDir 'sim/tb_polar_lane_equivalence.sv');Relative='test/tb_polar_lane_equivalence.sv'},
    [pscustomobject]@{Label='lane0 real parameter ROM';Source=(Join-Path $CandidateRoot 'rtl/audio/rom/polar_lane0.hex');Relative='candidate/rtl/audio/rom/polar_lane0.hex'},
    [pscustomobject]@{Label='lane1 real parameter ROM';Source=(Join-Path $CandidateRoot 'rtl/audio/rom/polar_lane1.hex');Relative='candidate/rtl/audio/rom/polar_lane1.hex'},
    [pscustomobject]@{Label='partial ratio ROM';Source=(Join-Path $CandidateRoot 'rtl/audio/rom/polar_ratios.hex');Relative='candidate/rtl/audio/rom/polar_ratios.hex'},
    [pscustomobject]@{Label='sine ROM';Source=(Join-Path $CandidateRoot 'rtl/audio/rom/sine.hex');Relative='candidate/rtl/audio/rom/sine.hex'},
    [pscustomobject]@{Label='effective reusable runner';Source=$PSCommandPath;Relative='scripts/test-modelsim-polar-equivalence.ps1'},
    [pscustomobject]@{Label='Windows PowerShell 5 launcher';Source=(Join-Path $PSScriptRoot 'test-modelsim-polar-equivalence.cmd');Relative='scripts/test-modelsim-polar-equivalence.cmd'}
)
$inputs=@()
foreach($source in $sources){
    $target=Join-Path $snapshot $source.Relative
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force|Out-Null
    $before=(Get-FileHash -LiteralPath $source.Source -Algorithm SHA256).Hash
    Copy-Item -LiteralPath $source.Source -Destination $target
    $snapshotHash=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    if($before -ne $snapshotHash){throw "Snapshot differs from source: $($source.Source)"}
    $inputs+=[pscustomobject]@{Label=$source.Label;Source=$source.Source;SnapshotPath=$target;Before=$before;Snapshot=$snapshotHash}
}
$referenceText=Get-Content -LiteralPath $inputs[1].SnapshotPath -Raw
$referenceSourceHash=[regex]::Match($referenceText,'Source SHA256: ([a-f0-9]{64})').Groups[1].Value
if(!$referenceSourceHash){throw 'Frozen reference source fingerprint is missing'}
# This deliberately wrong implementation writes state RAM half a clock early.
# Keep the staging registers so the independent s0/s1 oracle, rather than a
# missing internal signal, must detect changed read-before-write behavior.
$mutant=Join-Path $snapshot 'mutant/polar_lane_early_write.v'
New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($mutant))|Out-Null
$candidateText=Get-Content -LiteralPath $inputs[0].SnapshotPath -Raw
$writePattern='always @\(posedge clk\) begin\s+if\(state_write_valid\) states\[state_write_address\]<=state_write_data;\s+end'
if([regex]::Matches($candidateText,$writePattern).Count -ne 1){throw 'Expected exactly one candidate staged RAM write for mutation'}
$mutantText=[regex]::Replace($candidateText,$writePattern,@'
always @(negedge clk) begin
        if(rst_n && v[3]) states[addr3]<={end3,ptr3,aL3,aR3,tL3,tR3,enabled3 ? phase_after : 32'd0};
    end
'@)
[IO.File]::WriteAllText($mutant,$mutantText,[Text.Encoding]::ASCII)
$mutantHash=(Get-FileHash -LiteralPath $mutant -Algorithm SHA256).Hash
$work=(Join-Path $runDir 'work').Replace('\','/')
$mutantWork=(Join-Path $runDir 'mutant_work').Replace('\','/')
$ini=Join-Path $runDir 'modelsim.ini'
@('[Library]',"work = $work","mutant = $mutantWork",'[vsim]')|Set-Content -LiteralPath $ini -Encoding ASCII
$compileDo=Join-Path $runDir 'compile.do'
$compilePaths=@($inputs[0..2].SnapshotPath|ForEach-Object {'{'+$_.Replace('\','/')+'}'}) -join ' '
$mutantPaths=@(@($mutant)+@($inputs[1..2].SnapshotPath)|ForEach-Object {'{'+$_.Replace('\','/')+'}'}) -join ' '
@('onerror {quit -f -code 2}',"vlib {$work}","vlog -sv -work {$work} $compilePaths",
    "vlib {$mutantWork}","vlog -sv -work {$mutantWork} $mutantPaths",'quit -f -code 0')|
    Set-Content -LiteralPath $compileDo -Encoding ASCII
$vsim=Join-Path $resolvedBin 'vsim.exe'
function Invoke-ModelSim([string]$DoFile,[string]$Name){
    $log=Join-Path $runDir "$Name.log";$console=Join-Path $runDir "$Name.console.log"
    $preference=$ErrorActionPreference;$timer=[Diagnostics.Stopwatch]::StartNew()
    try{$ErrorActionPreference='Continue';& $vsim -c -modelsimini $ini -do $DoFile -l $log *> $console;$toolExit=$LASTEXITCODE}
    finally{$ErrorActionPreference=$preference}
    [pscustomobject]@{ExitCode=$toolExit;Text=((Get-Content -LiteralPath $log -Raw)+"`n"+(Get-Content -LiteralPath $console -Raw));
        ElapsedSeconds=$timer.Elapsed.TotalSeconds;Log=$log;Console=$console;
        LogSHA256=(Get-FileHash -LiteralPath $log -Algorithm SHA256).Hash;ConsoleSHA256=(Get-FileHash -LiteralPath $console -Algorithm SHA256).Hash}
}
$cases=@();$location=Get-Location;$total=[Diagnostics.Stopwatch]::StartNew()
try{
    # The unmodified TB reads candidate/rtl/audio/rom/. This layout makes it
    # consume the copied CandidateRoot ROMs, even when testing the main project.
    Set-Location -LiteralPath $snapshot
    $compile=Invoke-ModelSim $compileDo 'compile'
    if($compile.ExitCode -ne 0 -or $compile.Text -match '(?im)^\s*#?\s*\*\*\s+(Error|Fatal)(\s|:)' -or $compile.Text -match 'Errors:\s*[1-9]'){
        throw "Polar equivalence compilation failed: $($compile.Log)"
    }
    $selected=@([pscustomobject]@{Name='oracle_negative';Seed=$Seeds[0];Negative=$true;Mutation=$false})
    foreach($seed in $Seeds){$selected+=[pscustomobject]@{Name="seed_$seed";Seed=$seed;Negative=$false;Mutation=$false}}
    $selected+=[pscustomobject]@{Name='early_write_mutant';Seed=$Seeds[0];Negative=$false;Mutation=$true}
    foreach($case in $selected){
        $doFile=Join-Path $runDir "$($case.Name).do"
        $wave=(Join-Path $runDir "$($case.Name).wlf").Replace('\','/')
        $extra=if($case.Negative){' +ORACLE_NEGATIVE'}else{''}
        $library=if($case.Mutation){'mutant'}else{'work'}
        @('onerror {quit -f -code 2}','onbreak {quit -f -code 3}',
            "vsim -onfinish exit -wlf {$wave} $library.tb_polar_lane_equivalence +SEED=$($case.Seed) +TRANSACTIONS=$RandomTransactions$extra",
            'run -all','quit -f -code 0')|Set-Content -LiteralPath $doFile -Encoding ASCII
        $result=Invoke-ModelSim $doFile $case.Name
        $hasFatal=$result.Text -match '(?im)^\s*#?\s*\*\*\s+Fatal:'
        $hasError=$result.Text -match '(?im)^\s*#?\s*\*\*\s+Error(?:\s|:)'
        $marker=[regex]::Match($result.Text,'POLAR LANE EQUIVALENCE PASS[^\r\n]*').Value
        # ModelSim -onfinish exit can return zero on $fatal. Negative acceptance
        # requires exact oracle identity/time/instance and forbids a PASS marker.
        $matched=if($case.Negative){$hasFatal -and !$hasError -and !$marker -and $result.Text.Contains('polar output mismatch cycle=20') -and
            $result.Text.Contains('Time: 196 ns') -and $result.Text.Contains('Instance: /tb_polar_lane_equivalence')}
            elseif($case.Mutation){$hasFatal -and !$hasError -and !$marker -and
                $result.Text.Contains('polar RAM read-state mismatch cycle=1215 age=1 sameaddr=1/1') -and
                $result.Text.Contains('Time: 12146 ns') -and
                $result.Text.Contains('Instance: /tb_polar_lane_equivalence')}
            else{$result.ExitCode -eq 0 -and !$hasFatal -and !$hasError -and [bool]$marker}
        $cases+=[pscustomobject]@{Name=$case.Name;Seed=$case.Seed;ExpectedFatal=($case.Negative -or $case.Mutation);Mutation=$case.Mutation;Matched=$matched;
            ExitCode=$result.ExitCode;ElapsedSeconds=$result.ElapsedSeconds;Marker=$marker;Log=$result.Log;Console=$result.Console;
            LogSHA256=$result.LogSHA256;ConsoleSHA256=$result.ConsoleSHA256}
        Write-Host "$($case.Name): matched=$matched exit=$($result.ExitCode) $marker"
    }
}finally{Set-Location -LiteralPath $location.Path}
foreach($item in $inputs){
    $item|Add-Member NoteProperty After (Get-FileHash -LiteralPath $item.Source -Algorithm SHA256).Hash
    $item|Add-Member NoteProperty SnapshotAfter (Get-FileHash -LiteralPath $item.SnapshotPath -Algorithm SHA256).Hash
}
$unchanged=@($inputs|Where-Object {$_.Before -ne $_.After -or $_.Before -ne $_.SnapshotAfter}).Count -eq 0
$passed=$cases.Count -eq ($Seeds.Count+2) -and @($cases|Where-Object {!$_.Matched}).Count -eq 0 -and $unchanged
$summary=[pscustomobject]@{Passed=$passed;CandidateRoot=$CandidateRoot;Project=$projectDir;ResultDirectory=$runDir;Simulator=$vsim;
    ReferenceSourceSHA256=$referenceSourceHash;EffectivePolarLaneSHA256=$inputs[0].Snapshot;InputsUnchanged=$unchanged;
    RunnerSHA256=$inputs[7].Before;RunnerSnapshotSHA256=$inputs[7].Snapshot;RunnerAfterSHA256=$inputs[7].After;
    RandomTransactionsPerSeed=$RandomTransactions;ElapsedSeconds=$total.Elapsed.TotalSeconds;Cases=$cases;Inputs=$inputs;
    Mutation='RAM writes moved from rising to preceding falling edge';MutantSource=$mutant;MutantSHA256=$mutantHash;
    HardwareValidated=$false;TimingValidatedByThisTest=$false}
$summary|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $runDir 'summary.json') -Encoding UTF8
Write-Host "POLAR MODELSIM EQUIVALENCE results: $runDir"
if(!$passed){throw 'Polar equivalence failed; inspect the actual logs'}
