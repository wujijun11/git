# Run the complete run_tone.do test BEFORE converting its decoded serial audio.
$ErrorActionPreference = 'Stop'
$simDir = Join-Path $PSScriptRoot '../sim'
$log = Get-Content -LiteralPath (Join-Path $simDir 'test_tone_results.log') -Raw
if (!$log.Contains('ALL TONE TESTS PASSED')) { throw 'Run the complete tone test first.' }
$rows = @(Get-Content -LiteralPath (Join-Path $simDir 'tone_samples.csv'))
if ($rows.Count -ne 12000) { throw 'Expected 12000 verified decoded frames; rerun full test.' }
$wavPath = Join-Path $simDir 'tone_preview.wav'
$writer = [IO.BinaryWriter]::new([IO.File]::Create($wavPath))
try {
    $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'))
    $writer.Write([int](36 + $rows.Count * 6))
    $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
    $writer.Write([int]16)
    $writer.Write([int16]1)
    $writer.Write([int16]2)
    $writer.Write([int]48000)
    $writer.Write([int]288000)
    $writer.Write([int16]6)
    $writer.Write([int16]24)
    $writer.Write([Text.Encoding]::ASCII.GetBytes('data'))
    $writer.Write([int]($rows.Count * 6))
    foreach ($row in $rows) {
        foreach ($field in $row.Split(',')) {
            $sample = [int]$field
            if ($sample -lt -8388608 -or $sample -gt 8388607) { throw 'Invalid 24-bit sample' }
            $writer.Write([byte]($sample -band 255))
            $writer.Write([byte](($sample -shr 8) -band 255))
            $writer.Write([byte](($sample -shr 16) -band 255))
        }
    }
} finally { $writer.Dispose() }
Write-Output "Created $wavPath (24-bit stereo, 48000 Hz, 0.25 seconds)"

# Listening convenience only: repeat the verified 0.25-second capture 20 times.
# This is NOT evidence of a 5-second RTL simulation. Keep the raw file above.
$previewFrames = $rows.Count * 20
$decoded = [int[]]::new($rows.Count * 2)
for ($i = 0; $i -lt $rows.Count; $i++) {
    $pair = $rows[$i].Split(',')
    $decoded[2*$i] = [int]$pair[0]
    $decoded[2*$i+1] = [int]$pair[1]
}
$previewPath = Join-Path $simDir 'tone_preview_5s.wav'
$writer = [IO.BinaryWriter]::new([IO.File]::Create($previewPath))
try {
    $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'))
    $writer.Write([int](36 + $previewFrames * 4))
    $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
    $writer.Write([int]16)
    $writer.Write([int16]1)
    $writer.Write([int16]2)
    $writer.Write([int]48000)
    $writer.Write([int]192000)
    $writer.Write([int16]4)
    $writer.Write([int16]16)
    $writer.Write([Text.Encoding]::ASCII.GetBytes('data'))
    $writer.Write([int]($previewFrames * 4))
    for ($i = 0; $i -lt $previewFrames; $i++) {
        $index = ($i % $rows.Count) * 2
        # A 10 ms fade at the ends avoids a click on playback start/stop.
        $gain = [Math]::Min(1.0, [Math]::Min($i / 480.0, ($previewFrames - 1 - $i) / 480.0))
        $writer.Write([int16][Math]::Round($decoded[$index] / 256.0 * $gain))
        $writer.Write([int16][Math]::Round($decoded[$index+1] / 256.0 * $gain))
    }
} finally { $writer.Dispose() }
Write-Output "Created $previewPath (16-bit stereo, 48000 Hz, 5 seconds; repeated capture)"
