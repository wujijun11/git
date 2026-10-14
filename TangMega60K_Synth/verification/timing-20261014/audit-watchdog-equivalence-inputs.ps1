$ErrorActionPreference='Stop'
$projectDir=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$runner=Join-Path $projectDir 'scripts/test-modelsim-watchdog-equivalence.ps1'
$tokens=$null;$parseErrors=$null
[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$parseErrors)|Out-Null
if($parseErrors.Count -ne 0){throw ($parseErrors|Out-String)}
$runs=@('watchdog_equivalence_20261014_194640_7ea7700c','watchdog_equivalence_20261014_194715_03d4ed52')
$audit=@()
foreach($name in $runs){
    $runDir=Join-Path $PSScriptRoot $name
    $summary=Get-Content -LiteralPath (Join-Path $runDir 'summary.json') -Raw|ConvertFrom-Json
    foreach($item in $summary.Inputs){
        $live=(Get-FileHash -LiteralPath (Join-Path $projectDir $item.Path) -Algorithm SHA256).Hash
        $snapshot=(Get-FileHash -LiteralPath (Join-Path $runDir ([IO.Path]::GetFileName($item.Path))) -Algorithm SHA256).Hash
        $baselineOverride=$summary.Baseline -and $item.Path -eq 'rtl/control/remote_note_watchdog.v'
        $expected=if($baselineOverride){$summary.ReferenceSourceSHA256}else{$item.Snapshot}
        $audit+=[pscustomobject]@{Run=$name;Path=$item.Path;Before=$item.CurrentBefore;RecordedSnapshot=$item.Snapshot;After=$item.CurrentAfter;
            RecordedAllEqual=($item.CurrentBefore -eq $item.Snapshot -and $item.Snapshot -eq $item.CurrentAfter);
            CurrentSHA256=$live;CurrentMatches=($live -eq $item.CurrentAfter);
            ActualSnapshotSHA256=$snapshot;ActualSnapshotMatches=($snapshot -eq $expected);
            BaselineOverride=$baselineOverride;
            BaselineEffectiveMatches=(!$baselineOverride -or $snapshot -eq $summary.EffectiveDutSHA256)}
    }
}
$passed=@($audit|Where-Object {!$_.RecordedAllEqual -or !$_.CurrentMatches -or !$_.ActualSnapshotMatches -or !$_.BaselineEffectiveMatches}).Count -eq 0
$result=[pscustomobject]@{Passed=$passed;SimulationRerun=$false;ParserErrors=0;
    TestedRunnerSHA256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'watchdog-equivalence-tested-runner-v1.ps1') -Algorithm SHA256).Hash;
    GuardRunnerSHA256=(Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash;
    Note='The new guard version was parsed and existing actual input fingerprints independently verified; no simulation rerun was needed because RTL, reference, and TB are unchanged.';
    Inputs=$audit}
$result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $PSScriptRoot 'watchdog-equivalence-guard-audit.json') -Encoding UTF8
Write-Host "INPUT FINGERPRINT AUDIT passed=$passed parser_errors=0 actual_source_groups=$($audit.Count)"
if(!$passed){throw 'Actual input fingerprint audit failed'}
