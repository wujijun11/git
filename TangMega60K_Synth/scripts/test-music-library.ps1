#requires -Version 7.0
param([string]$Python = '', [switch]$IncludeUI)
# 仅本机测试，不扫描蓝牙、不打开串口、不访问FPGA下载器。
$ErrorActionPreference = 'Stop'
$taskProject = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (!$Python) { $Python = Join-Path $taskProject 'tmp/desktop-python/Scripts/python.exe' }
Push-Location $taskProject
try {
    & $Python -m unittest discover -s desktop/tests -p test_music_library.py -v
    if ($LASTEXITCODE -ne 0) { throw 'Music library Python tests failed' }
    foreach ($taskTest in @('desktop/tests/test_controller.js', 'desktop/tests/test_queue.js', 'desktop/tests/test_score_upload.js')) {
        & node $taskTest
        if ($LASTEXITCODE -ne 0) { throw "Failed: $taskTest" }
    }
    if ($IncludeUI) {
        & node desktop/tests/test_music_ui.cjs
        if ($LASTEXITCODE -ne 0) { throw 'Music library browser test failed' }
    }
} finally { Pop-Location }
