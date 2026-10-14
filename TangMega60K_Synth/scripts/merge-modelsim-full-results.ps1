param(
    [Parameter(Mandatory=$true)][string]$BaseRun,
    [string[]]$AdditionalRun = @(),
    [ValidateSet('Core','Full')][string]$Suite = 'Core',
    [switch]$DeferLegacyN64,
    [string]$OutputDirectory = ''
)
$ErrorActionPreference='Stop'
$BaseRun=[IO.Path]::GetFullPath($BaseRun)
if(!$OutputDirectory){
    $OutputDirectory=Join-Path (Split-Path -Parent $BaseRun) ('acceptance_'+$Suite.ToLowerInvariant()+'_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N').Substring(0,8))
}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$coreKinds=@('Project','RTL','Testbench','ROM','Vendor')
function Read-Manifest([string]$RunDirectory){
    $path=Join-Path $RunDirectory 'manifest.json'
    if(!(Test-Path -LiteralPath $path)){throw "Run manifest missing: $path"}
    Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}
function Fingerprint($Inputs){
    $lines=@($Inputs | Where-Object {$_.Kind -in $coreKinds} | Sort-Object StagedPath | ForEach-Object {
        $_.Kind+'|'+$_.StagedPath+'|'+$_.Sha256Before
    })
    $sha=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($lines -join "`n")))).Replace('-','').ToLowerInvariant()}
    finally{$sha.Dispose()}
}
function Test-CaseEvidence([string]$RunDirectory,$Case,$Expected){
    if(!$Case.Passed -or $Case.TimedOut){return $false}
    if($Case.Top -cne $Expected.Top -or $Case.ExpectedMarker -cne $Expected.ExpectedMarker -or
       $Case.ExpectedFatal -cne $Expected.ExpectedFatal -or
       (ConvertTo-Json -InputObject @($Case.Generics) -Compress) -cne (ConvertTo-Json -InputObject @($Expected.Generics) -Compress)) {return $false}
    $log=Join-Path $RunDirectory $Case.Log
    if(!(Test-Path -LiteralPath $log)){return $false}
    $text=Get-Content -LiteralPath $log -Raw
    $fatals=@([regex]::Matches($text,'(?im)^\s*#?\s*\*\*\s+Fatal[^\r\n]*') | ForEach-Object Value)
    $errors=@([regex]::Matches($text,'(?im)^\s*#?\s*\*\*\s+Error(?:\s|:)[^\r\n]*') | ForEach-Object Value)
    if($Expected.ExpectedFatal){
        return ($Case.ExitCode -in @(0,1) -and $fatals.Count -eq 1 -and $errors.Count -eq 0 -and
            $fatals[0] -match ('\*\*\s+Fatal:\s*'+[regex]::Escape($Expected.ExpectedFatal)+'\s*$') -and
            $text -match '(?im)\bTime:\s*0\s+(?:fs|ps|ns|us|ms|sec|s)\b' -and
            $text -match ('(?im)\bInstance:\s*/'+[regex]::Escape($Expected.Top)+'/dut\b') -and
            $text -notmatch 'PARAMETER_NOT_REJECTED')
    }
    return ($Case.ExitCode -eq 0 -and $fatals.Count -eq 0 -and $errors.Count -eq 0 -and
        $text -notmatch '(?im)\bErrors:\s*[1-9][0-9]*' -and $text.Contains($Expected.ExpectedMarker))
}
$baseManifest=Read-Manifest $BaseRun
$catalog=@($baseManifest.Cases)
# BaseRun establishes the complete coverage contract. A filtered run can add
# evidence through AdditionalRun, but cannot shrink the acceptance denominator.
# Keep this release's exact catalog explicit and independent of run metadata.
$expectedFullNames=@(
    'full_system','global_panic','control_router','expression_merge','note_arbiter',
    'runtime_fx','runtime_fx_storage','remote_note_watchdog','audio_visualizer','audio_monitor_cdc',
    'watchdog_arbiter','mpr121_i2c','mpr121_frontend','mpr121_backpressure','mpr121_timing','mpr121_capacity',
    'performance','performance_retrigger','performance_commit','board_local_actions','ws2812_waveform',
    'ws2812_matrix','remote_uart','video_encoder','video_timing','video_vendor','audio_units',
    'audio_engine_n4','audio_engine_n64','audio_i2s','ws2812_reject_zero','ws2812_reject_large',
    'ws2812_reject_map','ws2812_reject_duplicate'
)
$missingNames=@($expectedFullNames | Where-Object {@($catalog.Name) -cnotcontains $_})
$unexpectedNames=@($catalog.Name | Where-Object {$expectedFullNames -cnotcontains $_})
if($baseManifest.Suite -cne 'Full' -or $catalog.Count -ne $expectedFullNames.Count -or
   @($catalog.Name | Group-Object | Where-Object Count -gt 1).Count -ne 0 -or
   $missingNames.Count -gt 0 -or $unexpectedNames.Count -gt 0){
    throw "BaseRun must contain the exact complete 34-case Full catalog. Filtered runs are allowed only as AdditionalRun. Missing: $($missingNames -join ', '); unexpected: $($unexpectedNames -join ', ')"
}
if($null -ne $baseManifest.FullCaseCount -and $baseManifest.FullCaseCount -ne $expectedFullNames.Count){
    throw 'BaseRun declared FullCaseCount does not match the complete 34-case catalog'
}
if($null -ne $baseManifest.ExpectedCases -and $baseManifest.ExpectedCases -ne $expectedFullNames.Count){
    throw 'BaseRun declared ExpectedCases does not match the complete 34-case catalog'
}
$baseFingerprint=Fingerprint $baseManifest.Inputs
$coreCatalog=@($catalog | Where-Object Name -ne 'audio_engine_n64')
$inputChecks=@()
$currentCoreMatches=$true
foreach($inputFile in @($baseManifest.Inputs | Where-Object {$_.Kind -in $coreKinds})){
    $actual=if(Test-Path -LiteralPath $inputFile.Source -PathType Leaf){(Get-FileHash -LiteralPath $inputFile.Source -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null}
    $match=$actual -ceq $inputFile.Sha256Before
    if(!$match){$currentCoreMatches=$false}
    $inputChecks+=@([pscustomobject]@{Kind=$inputFile.Kind;Source=$inputFile.Source;StagedPath=$inputFile.StagedPath;
        TestedSha256=$inputFile.Sha256Before;CurrentSha256=$actual;Matches=$match})
}
$runnerChanges=@()
foreach($inputFile in @($baseManifest.Inputs | Where-Object {$_.Kind -in @('Runner','Viewer')})){
    $actual=if(Test-Path -LiteralPath $inputFile.Source -PathType Leaf){(Get-FileHash -LiteralPath $inputFile.Source -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null}
    $runnerChanges+=@([pscustomobject]@{Kind=$inputFile.Kind;Source=$inputFile.Source;
        TestedSha256=$inputFile.Sha256Before;CurrentSha256=$actual;Changed=($actual -cne $inputFile.Sha256Before)})
}
$runRecords=@()
foreach($runDirectory in @($BaseRun)+@($AdditionalRun)){
    $runDirectory=[IO.Path]::GetFullPath($runDirectory)
    $runManifest=Read-Manifest $runDirectory
    $fingerprint=Fingerprint $runManifest.Inputs
    $snapshotChecks=@()
    $snapshotMatches=$true
    foreach($inputFile in @($runManifest.Inputs | Where-Object {$_.Kind -in $coreKinds})){
        $path=Join-Path $runDirectory $inputFile.StagedPath
        $actual=if(Test-Path -LiteralPath $path -PathType Leaf){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null}
        $matches=$actual -ceq $inputFile.Sha256Before
        if(!$matches){$snapshotMatches=$false}
        $snapshotChecks+=@([pscustomobject]@{Path=$path;Sha256=$actual;Matches=$matches})
    }
    $eligible=$runManifest.Compiled -eq $true -and $runManifest.InputsUnchanged -eq $true -and
        $runManifest.Status -in @('Passed','Failed') -and $snapshotMatches -and $fingerprint -ceq $baseFingerprint
    $runRecords+=@([pscustomobject]@{Directory=$runDirectory;Manifest=$runManifest;CoreFingerprint=$fingerprint;
        CoreFingerprintMatchesBase=($fingerprint -ceq $baseFingerprint);SnapshotsVerified=$snapshotMatches;
        EligibleForCaseEvidence=$eligible;SnapshotChecks=$snapshotChecks})
}
$caseRecords=@()
foreach($expected in $catalog){
    $history=@();$winner=$null
    foreach($runRecord in $runRecords){
        foreach($case in @($runRecord.Manifest.Cases | Where-Object {$_.Name -ceq $expected.Name})){
            $verified=$runRecord.EligibleForCaseEvidence -and (Test-CaseEvidence $runRecord.Directory $case $expected)
            $attemptStatus=if($verified){'Passed'}elseif($case.TimedOut){'TimedOut'}elseif($runRecord.Manifest.Status -eq 'Running'){'Running'}else{'Failed'}
            $caseLog=if($case.Log){$case.Log}else{'logs/'+$case.Name+'.log'}
            $attempt=[pscustomobject]@{Run=$runRecord.Directory;Status=$attemptStatus;Verified=$verified;
                ExitCode=$case.ExitCode;TimedOut=$case.TimedOut;Failure=$case.Failure;Log=(Join-Path $runRecord.Directory $caseLog)}
            $history+=@($attempt)
            if($verified){$winner=$attempt}
        }
    }
    $status=if($winner){'Passed'}elseif($expected.Name -eq 'audio_engine_n64' -and $DeferLegacyN64){'DeferredByUser'}
        elseif($history.Count -gt 0){$history[-1].Status}else{'Pending'}
    $caseRecords+=@([pscustomobject]@{Name=$expected.Name;Top=$expected.Top;Generics=$expected.Generics;
        ExpectedRejection=$expected.ExpectedRejection;Status=$status;VerifiedPassed=($null -ne $winner);
        SelectedEvidence=$winner;History=$history})
}
$corePassedCount=@($caseRecords | Where-Object {$_.Name -ne 'audio_engine_n64' -and $_.VerifiedPassed}).Count
$fullPassedCount=@($caseRecords | Where-Object VerifiedPassed).Count
$corePassed=$currentCoreMatches -and $corePassedCount -eq $coreCatalog.Count
$fullPassed=$currentCoreMatches -and $fullPassedCount -eq $catalog.Count
$suitePassed=if($Suite -eq 'Core'){$corePassed}else{$fullPassed}
$report=[ordered]@{SchemaVersion=1;GeneratedUtc=[DateTime]::UtcNow.ToString('o');Suite=$Suite;
    Aggregator=$PSCommandPath;AggregatorSha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant();
    BaseRun=$BaseRun;AdditionalRuns=@($AdditionalRun);CoreSourceFingerprint=$baseFingerprint;
    CurrentCoreInputsMatch=$currentCoreMatches;CoreInputCount=$inputChecks.Count;
    CoreExpectedCases=$coreCatalog.Count;CoreVerifiedPasses=$corePassedCount;CorePassed=$corePassed;
    FullExpectedCases=$catalog.Count;FullVerifiedPasses=$fullPassedCount;FullPassed=$fullPassed;
    FullStatus=if($fullPassed){'Passed'}elseif($DeferLegacyN64){'DeferredByUser'}else{'Pending'};
    Passed=$suitePassed;Status=if($suitePassed){'Passed'}else{'Pending'};
    LegacyN64DeferredByUser=[bool]$DeferLegacyN64;
    DeferralReason=if($DeferLegacyN64){'The user chose to complete the core regression and deliver results before the additional legacy N64 long test.'}else{$null};
    Cases=$caseRecords;InputChecks=$inputChecks;RunnerVersions=$runnerChanges;
    Runs=@($runRecords | Select-Object Directory,CoreFingerprint,CoreFingerprintMatchesBase,SnapshotsVerified,EligibleForCaseEvidence,SnapshotChecks);
    Scope='Verified case evidence from the listed runs; RTL/vendor simulation only, no physical hardware test';
    EvidenceMethod='Retain original manifests/logs. Verify tested and current RTL/TB/ROM/vendor/project hashes, immutable source snapshots, exact case parameters and success/failure transcript markers. Runner/viewer versions are recorded separately.'}
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'manifest.json') -Encoding UTF8
$lines=@(
    '# ModelSim regression acceptance',
    '',
    "Core: $corePassedCount/$($coreCatalog.Count) verified; CorePassed=$corePassed.",
    '',
    "Full: $fullPassedCount/$($catalog.Count) verified; FullPassed=$fullPassed; status=$($report.FullStatus).",
    '',
    "Current production RTL, testbench, ROM, vendor and project inputs match tested SHA256: $currentCoreMatches ($($inputChecks.Count) inputs).",
    '',
    "Base evidence: $BaseRun",
    '',
    'The original run and its logs are retained. The current runner defaults to Core; Full keeps the additional N64 test with a 7200-second default limit. Runner changes below do not alter the tested production inputs.',
    '',
    '| Case | Status | Evidence run |',
    '|---|---|---|'
)
foreach($case in $caseRecords){
    $evidence=if($case.SelectedEvidence){$case.SelectedEvidence.Run}else{'See retained attempt history in manifest.json'}
    $lines+=@('| '+$case.Name+' | '+$case.Status+' | '+$evidence+' |')
}
$lines+=@('','## Runner versions','')
foreach($runner in $runnerChanges){$lines+=@('- '+$runner.Source+': changed='+$runner.Changed+'; tested SHA256='+$runner.TestedSha256+'; current SHA256='+$runner.CurrentSha256)}
if($DeferLegacyN64){$lines+=@('','The additional legacy audio_engine_n64 case is DeferredByUser. Its original 600-second wall-clock timeout and partial measurement remain in the base run. It has no completed PASS result.')}
$lines+=@('','This acceptance covers RTL and vendor primitive simulation. It does not establish physical board, sensor, LED, display, audio or Bluetooth hardware acceptance.')
$lines | Set-Content -LiteralPath (Join-Path $OutputDirectory 'README.md') -Encoding UTF8
Write-Host "MODELSIM ACCEPTANCE Core=$corePassedCount/$($coreCatalog.Count), Full=$fullPassedCount/$($catalog.Count), current input hashes match=$currentCoreMatches"
Write-Host "Evidence: $OutputDirectory"
if(!$suitePassed){exit 2}
