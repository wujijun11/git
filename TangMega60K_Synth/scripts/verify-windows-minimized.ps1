param(
    [Parameter(Mandatory=$true)][string]$Python,
    [string]$Node = 'node',
    [string]$EvidenceDirectory,
    [switch]$WindowProbe,
    [switch]$IncludeUI
)
# 全部使用内存设备/离线界面，不扫描、不连接、不下载真实板卡。
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskEvidence = if ($EvidenceDirectory) { [IO.Path]::GetFullPath($EvidenceDirectory) } else { Join-Path $taskRoot 'verification/windows-minimized-20261027' }
New-Item -ItemType Directory -Force -Path $taskEvidence | Out-Null
Push-Location $taskRoot
try {
    & $Python -X utf8 -m unittest discover -s desktop/tests -p 'test_*.py' -v 2>&1 |
        Tee-Object -FilePath (Join-Path $taskEvidence 'python-tests.log')
    if ($LASTEXITCODE -ne 0) { throw 'Python regression failed.' }
    foreach ($taskCase in @('test_native_lease.cjs','test_realtime_score.js','test_controller.js','test_queue.js','test_score_upload.js','test_direct_score.js','test_mode_sync.js','test_learning.cjs')) {
        & $Node (Join-Path 'desktop/tests' $taskCase) 2>&1 | Tee-Object -FilePath (Join-Path $taskEvidence ($taskCase + '.log'))
        if ($LASTEXITCODE -ne 0) { throw "Failed: $taskCase" }
    }
    if ($IncludeUI) {
        & $Python -X utf8 mobile/tests/make_midi_fixtures.py
        if ($LASTEXITCODE -ne 0) { throw 'MIDI UI fixture generation failed.' }
        foreach ($taskCase in @('test_realtime_ui.cjs','test_direct_ui.cjs','test_learning_ui.cjs')) {
            & $Node (Join-Path 'desktop/tests' $taskCase) 2>&1 | Tee-Object -FilePath (Join-Path $taskEvidence ($taskCase + '.log'))
            if ($LASTEXITCODE -ne 0) { throw "UI failed: $taskCase" }
        }
    }
    if ($WindowProbe) {
        & $Python -X utf8 desktop/tests/probe_minimized_window.py --duration 12 --javascript-baseline --output (Join-Path $taskEvidence 'baseline-window.json')
        if ($LASTEXITCODE -ne 0) { throw 'Baseline reproduction failed to execute.' }
        & $Python -X utf8 desktop/tests/probe_minimized_window.py --duration 70 --output (Join-Path $taskEvidence 'native-window.json')
        if ($LASTEXITCODE -ne 0) { throw 'Native minimized-window probe failed.' }
    }
    'WINDOWS REGRESSION ACCEPTED; actual Bluetooth, DAC, OLED and LED panel not tested.'
} finally { Pop-Location }
