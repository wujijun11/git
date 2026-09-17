$ErrorActionPreference='Stop'
$resultDir=Join-Path $PSScriptRoot '../sim/audio_results'
function Tone-Amplitude([double[]]$samples,[double]$hz) {
    [double]$re=0; [double]$im=0
    for($i=0;$i -lt $samples.Length;$i++) {
        $angle=2*[math]::PI*$hz*$i/48000
        $re+=$samples[$i]*[math]::Cos($angle)
        $im+=$samples[$i]*[math]::Sin($angle)
    }
    return 2*[math]::Sqrt($re*$re+$im*$im)/$samples.Length
}
function Crossings([double[]]$samples) {
    $cross=[Collections.Generic.List[double]]::new()
    for($i=1;$i -lt $samples.Length;$i++) {
        if($samples[$i-1] -lt 0 -and $samples[$i] -ge 0) {
            $cross.Add(($i-1)-$samples[$i-1]/($samples[$i]-$samples[$i-1]))
        }
    }
    return ,$cross.ToArray()
}
$report=@()
foreach($n in @(4,64)) {
    $rows=Import-Csv -LiteralPath (Join-Path $resultDir "pcm_$n.csv")
    $sine=[double[]]@($rows | Where-Object segment -eq '0' | ForEach-Object { [double]$_.left })
    $organ=[double[]]@($rows | Where-Object segment -eq '5' | ForEach-Object { [double]$_.left })
    $vibrato=[double[]]@($rows | Where-Object segment -eq '4' | ForEach-Object { [double]$_.left })
    if($sine.Length -ne 4800 -or $organ.Length -ne 4800 -or $vibrato.Length -ne 21002) { throw 'Incomplete sample capture' }
    $s1=Tone-Amplitude $sine 440; $s2=Tone-Amplitude $sine 880; $s3=Tone-Amplitude $sine 1320
    $o1=Tone-Amplitude $organ 440; $o2=Tone-Amplitude $organ 880; $o3=Tone-Amplitude $organ 1320
    if($s2/$s1 -gt .002 -or $s3/$s1 -gt .002) { throw 'Sine contains unexpected harmonics' }
    if([math]::Abs($o2/$o1-.5) -gt .005 -or [math]::Abs($o3/$o1-.25) -gt .005) { throw 'Organ harmonic recipe mismatch' }
    # Estimate instantaneous cents from successive PCM zero crossings, then
    # measure the LOW-frequency upward zero crossings of that cents sequence.
    $cross=Crossings $vibrato
    $times=[Collections.Generic.List[double]]::new()
    $cents=[Collections.Generic.List[double]]::new()
    for($i=1;$i -lt $cross.Length;$i++) {
        $frequency=48000/($cross[$i]-$cross[$i-1])
        $times.Add(($cross[$i]+$cross[$i-1])/96000)
        $cents.Add(1200*[math]::Log($frequency/440,2))
    }
    $lfoCross=[Collections.Generic.List[double]]::new()
    for($i=1;$i -lt $cents.Count;$i++) {
        if($cents[$i-1] -lt 0 -and $cents[$i] -ge 0) {
            $lfoCross.Add($times[$i-1]-$cents[$i-1]*($times[$i]-$times[$i-1])/($cents[$i]-$cents[$i-1]))
        }
    }
    if($lfoCross.Count -lt 2) { throw 'Insufficient vibrato cycles' }
    $lfoHz=($lfoCross.Count-1)/($lfoCross[$lfoCross.Count-1]-$lfoCross[0])
    $minimum=($cents | Measure-Object -Minimum).Minimum
    $maximum=($cents | Measure-Object -Maximum).Maximum
    if([math]::Abs($lfoHz-5) -gt .05 -or [math]::Abs($minimum+100) -gt 3 -or [math]::Abs($maximum-100) -gt 3) {
        throw "PCM vibrato incorrect: rate=$lfoHz depth=$minimum..$maximum"
    }
    $item=[ordered]@{voices=$n; sine_h2_ratio=$s2/$s1; sine_h3_ratio=$s3/$s1;
        organ_h2_ratio=$o2/$o1; organ_h3_ratio=$o3/$o1;
        vibrato_hz=$lfoHz; vibrato_min_cents=$minimum; vibrato_max_cents=$maximum}
    $report+=$item
    Write-Host ($item | ConvertTo-Json -Compress)
}
[IO.File]::WriteAllText((Join-Path $resultDir 'spectrum_validation.json'),($report | ConvertTo-Json -Depth 5))
Write-Host 'PCM SPECTRUM AND VIBRATO PASSED for 4 and 64 voices'
