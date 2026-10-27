param(
    [string]$Python = 'C:\Users\asus\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',
    [switch]$SkipInstall,
    [string]$OutputDirectory,
    [string]$EvidenceDirectory,
    [string]$BuildDirectory,
    [string]$VirtualEnvironment
)
$ErrorActionPreference = 'Stop'
$taskDesktop = $PSScriptRoot
$taskRoot = Split-Path -Parent $taskDesktop
$taskVenv = if ($VirtualEnvironment) { [IO.Path]::GetFullPath($VirtualEnvironment) } else { Join-Path $taskRoot 'tmp/desktop-python' }
$taskPython = Join-Path $taskVenv 'Scripts/python.exe'
$taskCache = Join-Path $taskRoot 'tmp/desktop-pip-cache'
$taskWork = if ($BuildDirectory) { [IO.Path]::GetFullPath($BuildDirectory) } else { Join-Path $taskRoot 'tmp/desktop-pyinstaller' }
$taskDist = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $taskDesktop 'dist' }
$taskSpec = if ($BuildDirectory) { Join-Path $taskWork 'spec' } else { Join-Path $taskRoot 'tmp/desktop-spec' }
$taskEvidence = if ($EvidenceDirectory) { [IO.Path]::GetFullPath($EvidenceDirectory) } else { Join-Path $taskRoot 'verification/desktop-app-20261021' }
New-Item -ItemType Directory -Path $taskEvidence,$taskCache,$taskWork,$taskSpec -Force | Out-Null
if (-not (Test-Path -LiteralPath $taskPython)) {
    if (-not (Test-Path -LiteralPath $Python)) { throw 'Specify -Python with a Python 3.12 x64 interpreter.' }
    & $Python -m venv $taskVenv
    if ($LASTEXITCODE -ne 0) { throw 'Could not create project-local Python environment.' }
}
if (-not $SkipInstall) {
    & $taskPython -m pip install --disable-pip-version-check --cache-dir $taskCache -r (Join-Path $taskDesktop 'requirements.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Pinned desktop dependency installation failed.' }
}
if (-not (Test-Path -LiteralPath (Join-Path $taskDesktop 'web/index.html'))) { throw 'desktop/web/index.html is required before packaging.' }
# 部分Python发行版的ssl模块需要额外的公开证书策略文件。
# 必须随原ssl模块按同名打包；不能通过关闭证书校验绕过缺文件的问题。
$taskTlsFiles = @(& $taskPython -c "import json,ssl; from pathlib import Path; root=Path(ssl.__file__).parent; print(json.dumps([str(p) for p in [root/'codex-rejected-cas.pem'] if p.is_file()]))" | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect Python TLS runtime data.' }
$taskTlsArguments = @()
foreach ($taskTlsFile in $taskTlsFiles) { $taskTlsArguments += @('--add-data', ($taskTlsFile + ';.')) }
$taskInputs = @((Get-Item -LiteralPath (Join-Path $taskDesktop 'native_host.py')), (Get-Item -LiteralPath (Join-Path $taskDesktop 'ble_link.py'))) + @(Get-ChildItem -LiteralPath (Join-Path $taskDesktop 'web') -File -Recurse) + @(Get-ChildItem -LiteralPath (Join-Path $taskDesktop 'assets') -File -Recurse)
$taskInputs += @($taskTlsFiles | ForEach-Object { Get-Item -LiteralPath $_ })
$taskDeliveryInputs = @()
$taskInputs += @(Get-ChildItem -LiteralPath (Join-Path $taskDesktop 'score_library') -File -Recurse -Filter '*.py')
$taskInputs += Get-Item -LiteralPath (Join-Path $taskDesktop 'preferences.py')
$taskInputs += @(Get-ChildItem -LiteralPath (Join-Path $taskDesktop 'realtime_native') -File -Recurse -Filter '*.py')
if (Test-Path -LiteralPath (Join-Path $taskDesktop 'README.md')) { $taskDeliveryInputs += Get-Item -LiteralPath (Join-Path $taskDesktop 'README.md') }
if (Test-Path -LiteralPath (Join-Path $taskDesktop 'examples')) { $taskDeliveryInputs += @(Get-ChildItem -LiteralPath (Join-Path $taskDesktop 'examples') -File -Recurse) }
$taskInputs += $taskDeliveryInputs
$taskInputHashes = @{}
foreach ($taskInput in $taskInputs) { $taskInputHashes[$taskInput.FullName] = (Get-FileHash -LiteralPath $taskInput.FullName -Algorithm SHA256).Hash }
& $taskPython -m pip freeze | Set-Content -LiteralPath (Join-Path $taskEvidence 'installed-dependencies.txt') -Encoding utf8
& $taskPython -m PyInstaller --noconfirm --onedir --windowed --noupx --name TangNeonStudio `
    --distpath $taskDist --workpath $taskWork --specpath $taskSpec `
    --collect-all webview --collect-all bleak --collect-all winrt --collect-all pythonnet --collect-all clr_loader `
    --copy-metadata pyserial --copy-metadata mido `
    --hidden-import serial.tools.list_ports --hidden-import serial.tools.list_ports_windows `
    --icon (Join-Path $taskDesktop 'assets/neon.ico') `
    --add-data "$(Join-Path $taskDesktop 'web');web" --add-data "$(Join-Path $taskDesktop 'assets');assets" @taskTlsArguments (Join-Path $taskDesktop 'native_host.py') `
    2>&1 | Tee-Object -FilePath (Join-Path $taskEvidence 'pyinstaller.log')
if ($LASTEXITCODE -ne 0) { throw 'Desktop packaging failed.' }
foreach ($taskInput in $taskInputs) {
    if ((Get-FileHash -LiteralPath $taskInput.FullName -Algorithm SHA256).Hash -ne $taskInputHashes[$taskInput.FullName]) { throw 'An input changed while packaging. Run the build again to package the finished UI.' }
}
$taskExe = Join-Path $taskDist 'TangNeonStudio/TangNeonStudio.exe'
$taskTlsManifest = foreach ($taskTlsFile in $taskTlsFiles) {
    $taskTlsName = Split-Path -Leaf $taskTlsFile
    $taskBundled = Join-Path (Split-Path -Parent $taskExe) ('_internal/' + $taskTlsName)
    $taskHash = (Get-FileHash -LiteralPath $taskTlsFile -Algorithm SHA256).Hash
    if ((Get-FileHash -LiteralPath $taskBundled -Algorithm SHA256).Hash -ne $taskHash) { throw 'Bundled TLS runtime data does not match Python runtime.' }
    [pscustomobject]@{path=$taskTlsName;sha256=$taskHash}
}
$taskWebManifest = foreach ($taskInput in (Get-ChildItem -LiteralPath (Join-Path $taskDesktop 'web') -File -Recurse)) {
    $taskRelative = [IO.Path]::GetRelativePath((Join-Path $taskDesktop 'web'), $taskInput.FullName)
    $taskBundled = Join-Path (Join-Path $taskDist 'TangNeonStudio/_internal/web') $taskRelative
    $taskHash = (Get-FileHash -LiteralPath $taskInput.FullName -Algorithm SHA256).Hash
    if ((Get-FileHash -LiteralPath $taskBundled -Algorithm SHA256).Hash -ne $taskHash) { throw "Bundled UI asset does not match source: $taskRelative" }
    [pscustomobject]@{path=$taskRelative;sha256=$taskHash}
}
$taskAssetsManifest = foreach ($taskInput in (Get-ChildItem -LiteralPath (Join-Path $taskDesktop 'assets') -File -Recurse)) {
    $taskRelative = [IO.Path]::GetRelativePath((Join-Path $taskDesktop 'assets'), $taskInput.FullName)
    $taskBundled = Join-Path (Join-Path $taskDist 'TangNeonStudio/_internal/assets') $taskRelative
    $taskHash = (Get-FileHash -LiteralPath $taskInput.FullName -Algorithm SHA256).Hash
    if ((Get-FileHash -LiteralPath $taskBundled -Algorithm SHA256).Hash -ne $taskHash) { throw "Bundled application asset does not match source: $taskRelative" }
    [pscustomobject]@{path=$taskRelative;sha256=$taskHash}
}
$taskDeliveryManifest = foreach ($taskInput in $taskDeliveryInputs) {
    $taskRelative = [IO.Path]::GetRelativePath($taskDesktop, $taskInput.FullName)
    $taskBundled = Join-Path (Split-Path -Parent $taskExe) $taskRelative
    New-Item -ItemType Directory -Path (Split-Path -Parent $taskBundled) -Force | Out-Null
    Copy-Item -LiteralPath $taskInput.FullName -Destination $taskBundled -Force
    $taskHash = (Get-FileHash -LiteralPath $taskInput.FullName -Algorithm SHA256).Hash
    if ((Get-FileHash -LiteralPath $taskBundled -Algorithm SHA256).Hash -ne $taskHash) { throw "Delivery document does not match source: $taskRelative" }
    [pscustomobject]@{path=$taskRelative;sha256=$taskHash}
}
$taskSmoke = Join-Path $taskEvidence 'packaged-smoke-test.json'
$taskProcess = Start-Process -FilePath $taskExe -ArgumentList @('--smoke-test','--smoke-output',('"'+$taskSmoke+'"')) -PassThru -WindowStyle Hidden
if (-not $taskProcess.WaitForExit(30000)) {
    Stop-Process -Id $taskProcess.Id -Force
    throw 'Packaged smoke test exceeded 30 seconds.'
}
if ($taskProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $taskSmoke)) { throw 'Packaged dependency smoke test failed.' }
$taskReport = Get-Content -LiteralPath $taskSmoke -Raw | ConvertFrom-Json
if (-not $taskReport.ok) { throw 'Packaged smoke test reported missing dependencies or runtime.' }
$taskFiles = Get-ChildItem -LiteralPath (Split-Path -Parent $taskExe) -File -Recurse
[pscustomobject]@{
    executable = $taskExe
    exeSHA256 = (Get-FileHash -LiteralPath $taskExe -Algorithm SHA256).Hash
    nativeHostSHA256 = (Get-FileHash -LiteralPath (Join-Path $taskDesktop 'native_host.py') -Algorithm SHA256).Hash
    tlsRuntimeData = @($taskTlsManifest)
    pythonSources = @($taskInputs | Where-Object Extension -eq '.py' | ForEach-Object {
        [pscustomobject]@{path=[IO.Path]::GetRelativePath($taskDesktop,$_.FullName);sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
    })
    totalFiles = $taskFiles.Count
    totalBytes = ($taskFiles | Measure-Object -Property Length -Sum).Sum
    webAssets = @($taskWebManifest)
    applicationAssets = @($taskAssetsManifest)
    deliveryDocuments = @($taskDeliveryManifest)
    packagedSmokeTest = $taskSmoke
    hardwareConnectionTested = $false
} | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $taskEvidence 'build-manifest.json') -Encoding utf8
Write-Output "Portable app ready: $taskExe"
