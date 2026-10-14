param(
    [string]$Variant = 'timing',
    [switch]$PrepareOnly,
    [string]$SourceRoot,
    [string]$RunSnapshot,
    [int]$TimeoutSeconds = 2400
)
$ErrorActionPreference = 'Stop'
$driverPath = Join-Path $PSScriptRoot 'build-contest-isolated.py'
$driverArgs = @($driverPath, '--variant', $Variant, '--timeout-seconds', "$TimeoutSeconds")
if ($PrepareOnly) { $driverArgs += '--prepare-only' }
if ($SourceRoot) { $driverArgs += @('--source-root', $SourceRoot) }
if ($RunSnapshot) { $driverArgs += @('--run-snapshot', $RunSnapshot) }
& python @driverArgs
exit $LASTEXITCODE
