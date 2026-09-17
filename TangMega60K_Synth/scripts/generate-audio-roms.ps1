param([int]$SampleRate = 48000)
$ErrorActionPreference = 'Stop'
if ($SampleRate -lt 32000) { throw 'SampleRate must be >= 32000' }
$romDir = Join-Path $PSScriptRoot '../rtl/audio/rom'
[IO.Directory]::CreateDirectory($romDir) | Out-Null
function Save-Hex([string]$name, $values, [int]$digits) {
    $lines = @($values | ForEach-Object { ([long]$_).ToString("X$digits") })
    [IO.File]::WriteAllLines((Join-Path $romDir $name), $lines, [Text.Encoding]::ASCII)
}
$sine = @(0..1023 | ForEach-Object {
    ([long][math]::Round(32767*[math]::Sin(2*[math]::PI*$_/1024))) -band 65535
})
$waves = [Collections.Generic.List[long]]::new()
foreach ($bank in 0..2) {
    foreach ($k in 0..1023) {
        $theta = 2*[math]::PI*$k/1024
        $value = [math]::Sin($theta)
        if ($bank -eq 1) { $value = (4*$value+2*[math]::Sin(2*$theta)+[math]::Sin(3*$theta))/7 }
        if ($bank -eq 2) { $value = (4*$value+2*[math]::Sin(2*$theta))/6 }
        $waves.Add(([long][math]::Round(32767*$value)) -band 65535)
    }
}
# Fourth bank is a defined sine fallback, never uninitialized.
$waves.AddRange([long[]]$sine)
Save-Hex 'sine.hex' $sine 4
Save-Hex 'waves.hex' $waves 4
Save-Hex 'midi.hex' @(0..127 | ForEach-Object {
    [long][math]::Round(440*[math]::Pow(2,($_-69)/12.0)*4294967296.0/$SampleRate)
}) 8
Save-Hex 'velocity.hex' @(0..127 | ForEach-Object { [long][math]::Round($_*32768.0/127) }) 4
# Unsigned Q3.20. Address = integer cents + 2500. Unity is EXACTLY 2^20.
Save-Hex 'ratio.hex' @(-2500..2500 | ForEach-Object {
    [long][math]::Round([math]::Pow(2,$_ / 1200.0)*1048576)
}) 6
Write-Host "Generated deterministic audio ROMs for Fs=$SampleRate Hz"
