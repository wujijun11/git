$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
# 保持两端调度算法一致。修改请先改desktop/web的源文件，再运行本脚本。
Copy-Item -LiteralPath (Join-Path $taskRoot 'desktop/web/realtime-score.js') -Destination (Join-Path $taskRoot 'mobile/web/realtime-score.js') -Force
