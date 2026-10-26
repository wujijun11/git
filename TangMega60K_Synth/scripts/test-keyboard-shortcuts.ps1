param([switch]$IncludeUI)
# 只在临时文件和独立浏览器内验证，不扫描硬件，不写用户偏好。
$ErrorActionPreference='Stop'
$taskProject=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$taskPython=Join-Path $taskProject 'tmp/desktop-python/Scripts/python.exe'
Push-Location $taskProject
try {
    & $taskPython desktop/tests/test_preferences.py
    if($LASTEXITCODE -ne 0){throw 'Preference storage tests failed'}
    & node desktop/tests/test_keyboard_bindings.js
    if($LASTEXITCODE -ne 0){throw 'Shortcut model tests failed'}
    if($IncludeUI){
        & node desktop/tests/test_shortcut_ui.cjs
        if($LASTEXITCODE -ne 0){throw 'Shortcut browser tests failed'}
    }
} finally {Pop-Location}
