param([switch]$IncludeUI)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskEvidence = Join-Path $taskRoot 'verification/realtime-score'
$taskTemp = Join-Path $taskRoot 'tmp/realtime-tests'
New-Item -ItemType Directory -Force -Path $taskEvidence,$taskTemp | Out-Null
$taskOldTemp = $env:TEMP
$taskOldTmp = $env:TMP
Push-Location $taskRoot
try {
    # 测试生成文件放进工程，避免受限环境下的系统临时目录清理失败。
    $env:TEMP = $taskTemp
    $env:TMP = $taskTemp
    $taskPython = Join-Path $taskRoot 'tmp/desktop-python/Scripts/python.exe'
    & {
        foreach ($taskScript in @('test_realtime_score.js','test_controller.js','test_queue.js','test_score_upload.js','test_direct_score.js')) {
            & node (Join-Path 'desktop/tests' $taskScript)
            if ($LASTEXITCODE -ne 0) { throw "Failed: $taskScript" }
        }
        & node mobile/tests/test_protocol.js
        if ($LASTEXITCODE -ne 0) { throw 'Mobile protocol failed' }
        foreach ($taskPattern in @('test_realtime_midi.py','test_direct_midi.py','test_music_library.py')) {
            & $taskPython -u -m unittest discover -s desktop/tests -p $taskPattern
            if ($LASTEXITCODE -ne 0) { throw "Failed: $taskPattern" }
        }
        if ($IncludeUI) {
            foreach ($taskScript in @('desktop/tests/test_realtime_ui.cjs','desktop/tests/test_music_ui.cjs','desktop/tests/test_direct_ui.cjs','mobile/tests/test_music_ui.cjs','mobile/tests/test_mode_ui.cjs')) {
                & node $taskScript
                if ($LASTEXITCODE -ne 0) { throw "Failed: $taskScript" }
            }
        }
        'REALTIME REGRESSION ACCEPTED; actual Bluetooth and DAC not tested'
    } 2>&1 | Tee-Object -FilePath (Join-Path $taskEvidence 'regression-final.log')
} finally {
    Pop-Location
    $env:TEMP = $taskOldTemp
    $env:TMP = $taskOldTmp
}
