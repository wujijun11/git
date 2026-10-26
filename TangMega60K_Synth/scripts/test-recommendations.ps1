param([switch]$IncludeUI)
# 不连接蓝牙，不写FPGA；网络在单独的smoke脚本中明确运行。
$ErrorActionPreference='Stop'
$taskProject=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$taskPython=Join-Path $taskProject 'tmp/desktop-python/Scripts/python.exe'
Push-Location $taskProject
try {
    & $taskPython -m unittest discover -s desktop/tests -p test_recommendations.py -v
    if($LASTEXITCODE -ne 0){throw 'Recommendation backend tests failed'}
    if($IncludeUI){
        & node desktop/tests/test_recommendation_ui.cjs
        if($LASTEXITCODE -ne 0){throw 'Recommendation browser tests failed'}
    }
}finally{Pop-Location}
