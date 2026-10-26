[CmdletBinding()]
param(
    [string]$JavaHome = $env:JAVA_HOME,
    [string]$Python = 'python',
    [string]$ToolRoot = '',
    [string]$InitScript = '',
    [switch]$Offline,
    [switch]$RerunChecks,
    [switch]$SkipBootstrap
)
$ErrorActionPreference = 'Stop'
$projectDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$androidDir = Join-Path $projectDir 'mobile/android'
if (!$ToolRoot) { $ToolRoot = Join-Path (Split-Path $projectDir) 'tmp/android-build' }
$ToolRoot = [IO.Path]::GetFullPath($ToolRoot)
if (!$JavaHome) {
    $javaCommand = Get-Command java -ErrorAction SilentlyContinue
    if ($javaCommand) { $JavaHome = Split-Path (Split-Path $javaCommand.Source) }
}
if (!$JavaHome -or !(Test-Path -LiteralPath (Join-Path $JavaHome 'bin/javac.exe'))) {
    throw 'Pass -JavaHome with a JDK 17 or newer (Gradle 8.9 supports JDK through 22).'
}
if (!$SkipBootstrap -and !$Offline) {
    & $Python (Join-Path $androidDir 'tools/bootstrap.py') --tool-root $ToolRoot
    if ($LASTEXITCODE -ne 0) { throw 'Android tool download/checksum/extraction failed' }
}
$gradle = Join-Path $ToolRoot 'gradle-8.9/bin/gradle.bat'
$sdk = Join-Path $ToolRoot 'sdk'
if (!(Test-Path -LiteralPath $gradle) -or !(Test-Path -LiteralPath (Join-Path $sdk 'platforms/android-35/android.jar'))) {
    throw 'Local Android tools are missing. Run without -Offline and -SkipBootstrap first.'
}
New-Item -ItemType Directory -Force -Path $ToolRoot | Out-Null
$keystore = Join-Path $ToolRoot 'debug.keystore'
if (!(Test-Path -LiteralPath $keystore)) {
    & (Join-Path $JavaHome 'bin/keytool.exe') -genkeypair -noprompt -keystore $keystore -storepass android -keypass android -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 -dname 'CN=Android Debug,O=Android,C=US'
    if ($LASTEXITCODE -ne 0) { throw 'Development APK key generation failed' }
}
$oldJavaHome = $env:JAVA_HOME
$oldSdkRoot = $env:ANDROID_SDK_ROOT
try {
    $env:JAVA_HOME = $JavaHome
    $env:ANDROID_SDK_ROOT = $sdk
    # Java properties按ISO-8859-1读取，中文需写为Unicode转义，避免错误回退SDK路径。
    $taskSdkProperty = [regex]::Replace($sdk.Replace('\','/'), '[^\u0000-\u007f]', {
        param($taskMatch)
        '\u{0:x4}' -f [int][char]$taskMatch.Value
    })
    'sdk.dir=' + $taskSdkProperty | Set-Content -LiteralPath (Join-Path $androidDir 'local.properties') -Encoding ascii
    # AGP在Windows上默认拒绝含中文的工程路径。此选项仅影响本次构建；
    # 仍实际运行资源编译、APK组装和lint，不能把跳过路径预检查当成构建成功。
    $arguments = @('--no-daemon','--console','plain','--gradle-user-home',(Join-Path $ToolRoot 'gradle-home'),'-p',$androidDir,'-Pandroid.overridePathCheck=true',"-PtangDebugKeystore=$keystore",'assembleDebug','lintDebug')
    if ($Offline) { $arguments += '--offline' }
    if ($RerunChecks) { $arguments += '--rerun-tasks' }
    if ($InitScript) { $arguments += @('--init-script', [IO.Path]::GetFullPath($InitScript)) }
    # Java does not read the common HTTPS_PROXY environment variable itself.
    if ($env:HTTPS_PROXY) {
        $proxy = [Uri]$env:HTTPS_PROXY
        if ($proxy.UserInfo) { throw 'Use Gradle credentials configuration for authenticated proxies; never place secrets in process arguments.' }
        $arguments += @("-Dhttps.proxyHost=$($proxy.Host)","-Dhttps.proxyPort=$($proxy.Port)","-Dhttp.proxyHost=$($proxy.Host)","-Dhttp.proxyPort=$($proxy.Port)")
        # Keep local development services local, including optional init-script
        # repositories. Gradle's HTTP client does not consume NO_PROXY itself.
        $arguments += '-Dhttp.nonProxyHosts=127.*'
    }
    & $gradle @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Android APK assembly or lint failed; inspect the Gradle error above.' }
    $apk = Join-Path $androidDir 'app/build/outputs/apk/debug/app-debug.apk'
    $outputDir = Join-Path $androidDir 'output'
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    $output = Join-Path $outputDir 'TangSynthRemote-debug.apk'
    Copy-Item -LiteralPath $apk -Destination $output -Force
    & (Join-Path $sdk 'build-tools/35.0.0/apksigner.bat') verify --verbose $output
    if ($LASTEXITCODE -ne 0) { throw 'APK signature verification failed' }
    Get-FileHash -LiteralPath $output -Algorithm SHA256
    Write-Output "APK ready: $output"
} finally {
    $env:JAVA_HOME = $oldJavaHome
    $env:ANDROID_SDK_ROOT = $oldSdkRoot
}
