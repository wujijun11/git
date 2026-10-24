param(
    [string]$IcarusBin='C:\iverilog\bin',
    [string]$OutputRoot='verification\voice-headroom-20261020',
    [int]$TimeoutSeconds=180
)
$ErrorActionPreference='Stop'
$projectDir=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$iverilog=Join-Path $IcarusBin 'iverilog.exe'
$vvp=Join-Path $IcarusBin 'vvp.exe'
foreach($tool in @($iverilog,$vvp)) { if(!(Test-Path -LiteralPath $tool)) { throw "Icarus tool not found: $tool" } }
$outputBase=if([IO.Path]::IsPathRooted($OutputRoot)) {$OutputRoot} else {Join-Path $projectDir $OutputRoot}
$run=Join-Path $outputBase ('run_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $run | Out-Null
# Frozen copies prevent concurrent RTL edits from changing a running test.
# ROMs are copied exactly as present; no ROM generator is invoked.
Copy-Item -LiteralPath (Join-Path $projectDir 'rtl') -Destination $run -Recurse
Copy-Item -LiteralPath (Join-Path $projectDir 'sim\tb_voice_headroom.sv') -Destination $run
$inputHashes=@(Get-ChildItem -LiteralPath (Join-Path $run 'rtl') -Recurse -File | ForEach-Object {
    @{path=$_.FullName.Substring($run.Length+1);sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash;size=$_.Length}
})
$inputHashes+=@{path='tb_voice_headroom.sv';sha256=(Get-FileHash -LiteralPath (Join-Path $run 'tb_voice_headroom.sv') -Algorithm SHA256).Hash}
$inputHashes | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $run 'source-hashes.json') -Encoding UTF8
$sources=@(Get-ChildItem -LiteralPath (Join-Path $run 'rtl\audio') -Filter '*.v' -File | ForEach-Object {$_.FullName})
$started=Get-Date
Push-Location $run
try {
    & $iverilog -g2012 -s tb_voice_headroom -o voice-headroom.vvp tb_voice_headroom.sv @sources *> compile.log
    if($LASTEXITCODE -ne 0) { Get-Content -LiteralPath compile.log; throw "Headroom compile failed; evidence: $run" }
    $startInfo=New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName=$vvp
    $startInfo.Arguments='voice-headroom.vvp +PCM=voice_headroom_pcm.csv'
    $startInfo.WorkingDirectory=$run
    $startInfo.UseShellExecute=$false
    $startInfo.CreateNoWindow=$true
    $startInfo.RedirectStandardOutput=$true
    $startInfo.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$startInfo
    [void]$process.Start()
    $stdoutTask=$process.StandardOutput.ReadToEndAsync()
    $stderrTask=$process.StandardError.ReadToEndAsync()
    $finished=$process.WaitForExit($TimeoutSeconds*1000)
    if(!$finished) { $process.Kill();$process.WaitForExit() }
    $stdout=$stdoutTask.GetAwaiter().GetResult()
    $stderr=$stderrTask.GetAwaiter().GetResult()
    [IO.File]::WriteAllText((Join-Path $run 'simulation.log'),$stdout)
    [IO.File]::WriteAllText((Join-Path $run 'simulation.stderr.log'),$stderr)
    $passed=$finished -and $process.ExitCode -eq 0 -and $stdout.Contains('VOICE HEADROOM PASSED')
    $csvPath=Join-Path $run 'voice_headroom_pcm.csv'
    $result=[ordered]@{
        passed=$passed;startedAt=$started.ToString('o');endedAt=(Get-Date).ToString('o');
        timedOut=(!$finished);timeoutSeconds=$TimeoutSeconds;exitCode=$process.ExitCode;
        output=$run;sourceHashes='source-hashes.json';pcm='voice_headroom_pcm.csv';
        pcmSha256=$(if(Test-Path -LiteralPath $csvPath){(Get-FileHash -LiteralPath $csvPath -Algorithm SHA256).Hash}else{$null});
        scope='Real dual 64-voice PCM; gain-factor/count/release/backpressure/25 actual MIDI FTWs. Accelerated ADSR; not hardware timing or acoustic validation.'
    }
    $result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $run 'result.json') -Encoding UTF8
    $stdout
    if(!$passed) { throw "Voice headroom regression failed; evidence: $run" }
    Write-Output "HEADROOM EVIDENCE: $run"
} finally { Pop-Location }
