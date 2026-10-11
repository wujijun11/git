param([string]$NodeBinary='node',[string]$PythonBinary='python')
$ErrorActionPreference = 'Stop'
$projectDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if(!(Get-Command $NodeBinary -ErrorAction SilentlyContinue)){
    $NodeBinary=Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe'
}
if(!(Get-Command $PythonBinary -ErrorAction SilentlyContinue)){
    $PythonBinary=Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe'
}
& $NodeBinary --check (Join-Path $projectDir 'mobile/web/app.js')
if ($LASTEXITCODE -ne 0) { throw 'App JavaScript syntax failed' }
& $NodeBinary (Join-Path $projectDir 'mobile/tests/test_protocol.js')
if ($LASTEXITCODE -ne 0) { throw 'Mobile protocol tests failed' }
& $NodeBinary (Join-Path $projectDir 'mobile/tests/test_app_simulation.js')
if ($LASTEXITCODE -ne 0) { throw 'Mobile UI simulation failed' }
$previousNode=$env:TANG_TEST_NODE
try {
    $env:TANG_TEST_NODE=(Get-Command $NodeBinary).Source
    & $PythonBinary (Join-Path $projectDir 'mobile/tests/test_protocol.py')
    if ($LASTEXITCODE -ne 0) { throw 'Python/JS parity failed' }
} finally {$env:TANG_TEST_NODE=$previousNode}
