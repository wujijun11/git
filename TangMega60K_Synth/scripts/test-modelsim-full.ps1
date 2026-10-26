param(
    [ValidateSet('Core','Full','Watchdog')][string]$Suite = 'Core',
    [string[]]$CaseName = @(),
    [string]$ModelSimBin = 'D:/msim/modelsim_ase/win32aloem',
    [string]$VendorModel = 'C:/Gowin/Gowin_V1.9.12_x64/IDE/simlib/gw5a/prim_sim.v',
    [string]$OutputRoot = '',
    [ValidateRange(600,86400)][int]$TimeoutSeconds = 600,
    [ValidateRange(600,86400)][int]$AudioLongTimeoutSeconds = 7200
)
$ErrorActionPreference = 'Stop'
$projectDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (!$OutputRoot) { $OutputRoot = Join-Path $projectDir 'verification/modelsim-20261014' }
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)

# Resolve a complete tool installation without changing shared libraries/ini.
$toolCandidates = @($ModelSimBin, 'C:/msim/modelsim_ase/win32aloem',
    'C:/modelsim/modeltech64_10.6e/win64', 'C:/msim/modeltech64_10.6e/win64') |
    Select-Object -Unique
$resolvedBin = $null
foreach ($candidate in $toolCandidates) {
    $complete = $true
    foreach ($exe in @('vsim.exe','vlog.exe','vlib.exe')) {
        if (!(Test-Path -LiteralPath (Join-Path $candidate $exe))) { $complete = $false }
    }
    if ($complete) { $resolvedBin = [IO.Path]::GetFullPath($candidate); break }
}
if (!$resolvedBin) { throw "ModelSim installation not found: $($toolCandidates -join ', ')" }
if (!(Test-Path -LiteralPath $VendorModel)) { throw "Gowin GW5A model missing: $VendorModel" }
$VendorModel = [IO.Path]::GetFullPath($VendorModel)
$runName = 'run_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [guid]::NewGuid().ToString('N').Substring(0,8)
$resultDir = Join-Path $OutputRoot $runName
New-Item -ItemType Directory -Path $resultDir -Force | Out-Null
foreach ($folder in @('logs','cases','waves','sim/audio_results','vendor')) {
    New-Item -ItemType Directory -Path (Join-Path $resultDir $folder) -Force | Out-Null
}
Write-Host "ModelSim $Suite regression: $resultDir"

function New-TestCase([string]$Name,[string]$Top,[string]$Bench,[string]$Marker,
    [string[]]$Generics = @(),[string]$ExpectedFatal = '',[bool]$SaveWave = $false) {
    [pscustomobject]@{Name=$Name;Top=$Top;Bench=$Bench;Marker=$Marker;
        Generics=$Generics;ExpectedFatal=$ExpectedFatal;SaveWave=$SaveWave}
}
$watchdogCase = New-TestCase 'remote_note_watchdog' 'tb_remote_note_watchdog' `
    'sim/tb_remote_note_watchdog.sv' 'REMOTE NOTE WATCHDOG PASS' @() '' $true
$allCases = @(
    (New-TestCase 'oled_timing_regression' 'tb_oled_timing_regression' 'sim/tb_oled_timing_regression.sv' 'OLED TIMING REGRESSION PASS'),
    (New-TestCase 'oled_board' 'tb_oled_board_integration' 'sim/tb_oled_board_integration.sv' 'OLED BOARD INTEGRATION PASS'),
    (New-TestCase 'oled_board_timing' 'tb_oled_board_integration' 'sim/tb_oled_board_integration.sv' 'OLED BOARD TIMING PASS' @('-gFAST=0')),
    (New-TestCase 'learning_mode' 'tb_learning_mode' 'sim/tb_learning_mode.sv' 'LEARNING MODE PASS'),
    (New-TestCase 'learning_status' 'tb_learning_status' 'sim/tb_learning_status.sv' 'LEARNING STATUS PASS'),
    (New-TestCase 'learning_system' 'tb_learning_system' 'sim/tb_learning_system.sv' 'LEARNING SYSTEM PASS'),

    (New-TestCase 'direct_score' 'tb_direct_score' 'sim/tb_direct_score.sv' 'DIRECT SCORE PASS'),
    (New-TestCase 'performance_stage' 'tb_performance_command_stage' 'sim/tb_performance_command_stage.sv' 'PERFORMANCE COMMAND STAGE PASS'),
    (New-TestCase 'direct_capability' 'tb_direct_capability' 'sim/tb_direct_capability.sv' 'DIRECT CAPABILITY PASS'),
    (New-TestCase 'direct_system' 'tb_direct_score_system' 'sim/tb_direct_score_system.sv' 'DIRECT SYSTEM PASS'),
    (New-TestCase 'score_capacity_1024' 'tb_score_capacity_1024' 'sim/tb_score_capacity_1024.sv' 'SCORE 1024 PASS'),
    (New-TestCase 'headroom_audit' 'tb_headroom_audit' 'sim/tb_headroom_audit.sv' 'HEADROOM AUDIT CAPTURE PASS'),
    (New-TestCase 'menu_system' 'tb_menu_system' 'sim/tb_menu_system.sv' 'MENU SYSTEM PASS'),
    (New-TestCase 'mode_status' 'tb_mode_status' 'sim/tb_mode_status.sv' 'MODE STATUS PASS'),
    (New-TestCase 'oled_menu' 'tb_oled_menu' 'sim/tb_oled_menu.sv' 'OLED MENU PASS'),
    (New-TestCase 'ui_tone' 'tb_ui_tone_overlay' 'sim/tb_ui_tone_overlay.sv' 'UI TONE PASS'),
    (New-TestCase 'slider_menu' 'tb_slider_menu' 'sim/tb_slider_menu.sv' 'SLIDER MENU PASS'),
    (New-TestCase 'menu_replay' 'tb_menu_replay' 'sim/tb_menu_replay.sv' 'MENU REPLAY PASS'),
    (New-TestCase 'full_system' 'tb_instrument_full_system' 'sim/tb_instrument_full_system.sv' 'FULL SYSTEM PASS' @() '' $true),
    (New-TestCase 'global_panic' 'tb_global_panic' 'sim/tb_global_panic.sv' 'GLOBAL PANIC PASS'),
    (New-TestCase 'control_router' 'tb_full_control' 'sim/tb_full_control.sv' 'FULL CONTROL ROUTER PASS'),
    (New-TestCase 'expression_merge' 'tb_expression_merge' 'sim/tb_full_control.sv' 'EXPRESSION MERGE PASS'),
    (New-TestCase 'note_arbiter' 'tb_note_arbiter' 'sim/tb_full_control.sv' 'NOTE ARBITER PASS'),
    (New-TestCase 'runtime_fx' 'tb_runtime_audio_fx' 'sim/tb_runtime_audio_fx.sv' 'RUNTIME AUDIO FX PASS'),
    (New-TestCase 'runtime_fx_storage' 'tb_runtime_audio_fx_storage' 'sim/tb_runtime_audio_fx_storage.sv' 'RUNTIME AUDIO FX STORAGE PASS bit-exact shared/separate histories'),
    $watchdogCase,
    (New-TestCase 'audio_visualizer' 'tb_audio_visualizer' 'sim/tb_audio_visualizer.sv' 'AUDIO VISUALIZER PASS'),
    (New-TestCase 'audio_monitor_cdc' 'tb_audio_monitor_cdc' 'sim/tb_audio_monitor_cdc.sv' 'AUDIO MONITOR CDC PASS'),
    (New-TestCase 'watchdog_arbiter' 'tb_watchdog_arbiter_integration' 'sim/tb_watchdog_arbiter_integration.sv' 'PASS watchdog/arbiter integration:'),
    (New-TestCase 'mpr121_i2c' 'tb_mpr121_i2c' 'sim/tb_mpr121_i2c.sv' 'PASS tb_mpr121_i2c'),
    (New-TestCase 'mpr121_frontend' 'tb_mpr121_frontend' 'sim/tb_mpr121_frontend.sv' 'PASS tb_mpr121_frontend'),
    (New-TestCase 'mpr121_backpressure' 'tb_mpr121_backpressure' 'sim/tb_mpr121_backpressure.sv' 'PASS tb_mpr121_backpressure'),
    (New-TestCase 'mpr121_timing' 'tb_mpr121_timing' 'sim/tb_mpr121_timing.sv' 'PASS tb_mpr121_timing'),
    (New-TestCase 'mpr121_capacity' 'tb_mpr121_eventizer_capacity' 'sim/tb_mpr121_eventizer_capacity.sv' 'PASS tb_mpr121_eventizer_capacity'),
    (New-TestCase 'performance' 'tb_performance_controller' 'sim/tb_performance_controller.sv' 'PASS performance:'),
    (New-TestCase 'performance_retrigger' 'tb_performance_retrigger' 'sim/tb_performance_retrigger.sv' 'PASS performance retrigger:'),
    (New-TestCase 'performance_commit' 'tb_performance_commit_pipeline' 'sim/tb_performance_commit_pipeline.sv' 'PASS performance consecutive commands:'),
    (New-TestCase 'board_local_actions' 'tb_board_local_actions' 'sim/tb_board_local_actions.sv' 'BOARD LOCAL ACTIONS PASS'),
    (New-TestCase 'ws2812_waveform' 'tb_performance_ws2812' 'sim/tb_performance_ws2812.sv' 'ALL WS2812 WAVEFORM TESTS PASSED'),
    (New-TestCase 'ws2812_matrix' 'tb_ws2812_matrix' 'sim/tb_ws2812_matrix.sv' 'ALL WS2812 MATRIX TESTS PASSED' @() '' $true),
    (New-TestCase 'remote_uart' 'tb_remote_uart_transport' 'sim/tb_remote_uart_transport.sv' 'ALL REMOTE UART TESTS PASSED'),
    (New-TestCase 'video_encoder' 'tb_video_encoder' 'sim/tb_video_encoder.sv' 'ALL VIDEO TMDS ENCODER TESTS PASSED'),
    (New-TestCase 'video_timing' 'tb_video_timing' 'sim/tb_video_timing.sv' 'ALL VIDEO TIMING TESTS PASSED'),
    (New-TestCase 'video_vendor' 'tb_video_vendor' 'sim/tb_video_vendor.sv' 'ALL VIDEO VENDOR TESTS PASSED'),
    (New-TestCase 'audio_units' 'tb_audio_units' 'sim/tb_audio_units.sv' 'AUDIO DSP UNITS PASSED'),
    (New-TestCase 'audio_engine_n4' 'tb_audio_engine' 'sim/tb_audio_engine.sv' 'AUDIO ENGINE PASSED N=4' @('-gN=4')),
    (New-TestCase 'audio_engine_n64' 'tb_audio_engine' 'sim/tb_audio_engine.sv' 'AUDIO ENGINE PASSED N=64' @('-gN=64')),
    (New-TestCase 'audio_i2s' 'tb_audio_i2s' 'sim/tb_audio_i2s.sv' 'AUDIO I2S INTEGRATION PASSED'),
    (New-TestCase 'ws2812_reject_zero' 'tb_ws2812_invalid_zero_count' 'sim/tb_ws2812_matrix.sv' '' @() 'WS2812 LED_COUNT must be 1..25'),
    (New-TestCase 'ws2812_reject_large' 'tb_ws2812_invalid_large_count' 'sim/tb_ws2812_matrix.sv' '' @() 'WS2812 LED_COUNT must be 1..25'),
    (New-TestCase 'ws2812_reject_map' 'tb_ws2812_invalid_key_map' 'sim/tb_ws2812_matrix.sv' '' @() 'WS2812 map key out of range'),
    (New-TestCase 'ws2812_reject_duplicate' 'tb_ws2812_duplicate_key_map' 'sim/tb_ws2812_matrix.sv' '' @() 'WS2812 map must be a permutation of 0..24')
)
$suiteCases = if ($Suite -eq 'Watchdog') { @($watchdogCase) }
    elseif ($Suite -eq 'Core') { @($allCases | Where-Object Name -ne 'audio_engine_n64') }
    else { $allCases }
if (@($CaseName | Group-Object | Where-Object Count -gt 1).Count -ne 0) {
    throw 'CaseName contains duplicate names'
}
foreach ($requestedName in $CaseName) {
    if (@($suiteCases.Name) -cnotcontains $requestedName) {
        throw "Unknown case for suite $Suite`: $requestedName. Choose an exact name: $($suiteCases.Name -join ', ')"
    }
}
$cases = if ($CaseName.Count -gt 0) { @($suiteCases | Where-Object { $CaseName -ccontains $_.Name }) }
    else { $suiteCases }

function Save-Json([string]$Path,$Value) {
    ConvertTo-Json -InputObject $Value -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}
function Get-Text([string]$Path) {
    if (Test-Path -LiteralPath $Path) { return [string](Get-Content -LiteralPath $Path -Raw) }
    return ''
}
function Tcl-Quote([string]$Value) {
    '"' + $Value.Replace('\','/').Replace('"','\"').Replace('$','\$').Replace('[','\[').Replace(']','\]') + '"'
}
function Invoke-CompileTool([string]$Executable,[string[]]$ToolArguments,[string]$Log) {
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Executable @ToolArguments *> $Log
        $toolExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    $compileText = Get-Text $Log
    if ($toolExit -ne 0 -or $compileText -match '(?im)^\s*#?\s*\*\*\s+(?:Error|Fatal)(?:\s|:)' -or
        $compileText -match '(?im)\bErrors:\s*[1-9][0-9]*') {
        throw "ModelSim compilation failed (exit $toolExit). See $Log"
    }
}
function Invoke-Simulation([string[]]$ToolArguments,[string]$CaseName,[int]$CaseTimeoutSeconds) {
    $pidFile = Join-Path $resultDir "logs/$CaseName.worker.pid"
    $exitFile = Join-Path $resultDir "logs/$CaseName.exitcode"
    $consoleFile = Join-Path $resultDir "logs/$CaseName.console.log"
    $config = [pscustomobject]@{Executable=(Join-Path $resolvedBin 'vsim.exe');Arguments=$ToolArguments;
        WorkingDirectory=$resultDir;PidFile=$pidFile;ExitFile=$exitFile;ConsoleFile=$consoleFile}
    # Start-Job owns a hidden PowerShell worker. Its PID is recorded before
    # spawning vsim, so a timeout can kill this worker's tree and no GUI process.
    $job = Start-Job -ScriptBlock {
        param($taskConfig)
        $ErrorActionPreference = 'Continue'
        Set-Content -LiteralPath $taskConfig.PidFile -Value $PID -Encoding ASCII
        Set-Location -LiteralPath $taskConfig.WorkingDirectory
        $taskExecutable = $taskConfig.Executable
        $taskArguments = @($taskConfig.Arguments)
        $taskConsole = $taskConfig.ConsoleFile
        & $taskExecutable @taskArguments *> $taskConsole
        Set-Content -LiteralPath $taskConfig.ExitFile -Value $LASTEXITCODE -Encoding ASCII
    } -ArgumentList $config
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $completed = Wait-Job -Job $job -Timeout $CaseTimeoutSeconds
        if (!$completed) {
            if (Test-Path -LiteralPath $pidFile) {
                $workerPid = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
                if ($workerPid -gt 0 -and $workerPid -ne $PID) {
                    $killArgs = @('/PID',[string]$workerPid,'/T','/F')
                    & (Join-Path $env:SystemRoot 'System32/taskkill.exe') @killArgs *> (Join-Path $resultDir "logs/$CaseName.timeout.log")
                }
            }
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            return [pscustomobject]@{ExitCode=$null;TimedOut=$true;ElapsedSeconds=$timer.Elapsed.TotalSeconds}
        }
        Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
        if (!(Test-Path -LiteralPath $exitFile)) {
            throw "Simulator worker failed without an exit code: $CaseName ($($job.State))"
        }
        return [pscustomobject]@{ExitCode=[int](Get-Content -LiteralPath $exitFile -Raw).Trim();
            TimedOut=$false;ElapsedSeconds=$timer.Elapsed.TotalSeconds}
    } finally {
        $timer.Stop()
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

$inputs = [Collections.Generic.List[object]]::new()
function Stage-Input([string]$Source,[string]$Relative,[string]$Kind) {
    $absoluteSource = [IO.Path]::GetFullPath($Source)
    if (!(Test-Path -LiteralPath $absoluteSource -PathType Leaf)) { throw "Input missing: $absoluteSource" }
    $hash = (Get-FileHash -LiteralPath $absoluteSource -Algorithm SHA256).Hash.ToLowerInvariant()
    $destination = Join-Path $resultDir $Relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $absoluteSource -Destination $destination
    if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) {
        throw "Input changed while staging: $absoluteSource"
    }
    $inputs.Add([pscustomobject]@{Kind=$Kind;Source=$absoluteSource;StagedPath=$Relative.Replace('\','/');
        Sha256Before=$hash;Sha256After=$null;Unchanged=$null})
}

$results = [Collections.Generic.List[object]]::new()
$startUtc = [DateTime]::UtcNow.ToString('o')
$infrastructureError = $null
$compiled = $false
$unchanged = $true
Push-Location $resultDir
try {
    $projectManifest = Join-Path $projectDir 'full/ContestFull.gprj'
    Stage-Input $projectManifest 'full/ContestFull.gprj' 'Project'
    [xml]$manifestXml = Get-Content -LiteralPath (Join-Path $resultDir 'full/ContestFull.gprj')
    $rtlSources = @($manifestXml.Project.FileList.File | Where-Object {
        $_.type -eq 'file.verilog' -and $_.enable -eq '1'
    } | ForEach-Object {
        $absolute = [IO.Path]::GetFullPath((Join-Path (Join-Path $projectDir 'full') $_.path))
        if (!$absolute.StartsWith($projectDir + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
            throw "Project source outside repository: $absolute"
        }
        $relative = $absolute.Substring($projectDir.Length+1).Replace('\','/')
        Stage-Input $absolute $relative 'RTL'
        $relative
    })
    if ($rtlSources.Count -eq 0 -or @($rtlSources | Select-Object -Unique).Count -ne $rtlSources.Count) {
        throw 'ContestFull RTL source list is empty or contains duplicate paths'
    }
    $benchSources = @($cases.Bench | Select-Object -Unique)
    if ($Suite -ne 'Watchdog') { $benchSources += @('sim/tb_mpr121_model.sv','sim/runtime_audio_fx_reference.sv') }
    # A filtered run retains the complete Full source fingerprint, allowing
    # evidence from separate runs to be compared without weakening coverage.
    $stagedBenchSources = if ($Suite -ne 'Watchdog') {
        @($allCases.Bench | Select-Object -Unique) + @('sim/tb_mpr121_model.sv','sim/runtime_audio_fx_reference.sv')
    } else { $benchSources }
    foreach ($bench in $stagedBenchSources) { Stage-Input (Join-Path $projectDir $bench) $bench 'Testbench' }
    foreach ($rom in (Get-ChildItem -LiteralPath (Join-Path $projectDir 'rtl/audio/rom') -File -Filter '*.hex' | Sort-Object Name)) {
        Stage-Input $rom.FullName ('rtl/audio/rom/' + $rom.Name) 'ROM'
    }
    Stage-Input (Join-Path $projectDir 'rtl/visual/goertzel_1024_64.hex') 'rtl/visual/goertzel_1024_64.hex' 'ROM'
    Stage-Input $VendorModel 'vendor/gw5a_prim_sim.v' 'Vendor'
    Stage-Input $PSCommandPath 'scripts/test-modelsim-full.ps1' 'Runner'
    Stage-Input (Join-Path $PSScriptRoot 'test-modelsim-full.cmd') 'scripts/test-modelsim-full.cmd' 'Runner'
    Stage-Input (Join-Path $projectDir 'sim/view_full_modelsim.do') 'sim/view_full_modelsim.do' 'Viewer'
    Save-Json (Join-Path $resultDir 'inputs.json') @($inputs.ToArray())
    Save-Json (Join-Path $resultDir 'manifest.json') ([ordered]@{Suite=$Suite;StartedUtc=$startUtc;
        Project=$projectDir;ResultDirectory=$resultDir;ModelSimBin=$resolvedBin;VendorModel=$VendorModel;
        SourceCount=$rtlSources.Count;TimeoutSeconds=$TimeoutSeconds;AudioLongTimeoutSeconds=$AudioLongTimeoutSeconds;
        SuiteCaseCount=$suiteCases.Count;FullCaseCount=$allCases.Count;SelectedCaseNames=@($cases.Name);
        Cases=$cases;Inputs=@($inputs.ToArray());
        Scope='RTL and vendor primitive simulation; no physical hardware test';Status='Running'})
    "[Library]`r`nwork = work`r`n`r`n[vsim]`r`nTranscriptFile = transcript`r`n" |
        Set-Content -LiteralPath 'modelsim.ini' -Encoding ASCII
    Write-Host "Compiling $($rtlSources.Count) production sources and $($benchSources.Count) explicit testbench files."
    Invoke-CompileTool (Join-Path $resolvedBin 'vlib.exe') @('work') (Join-Path $resultDir 'logs/vlib.log')
    Invoke-CompileTool (Join-Path $resolvedBin 'vlog.exe') @('-modelsimini','modelsim.ini','-work','work','vendor/gw5a_prim_sim.v') (Join-Path $resultDir 'logs/vendor.compile.log')
    $rtlArgs = @('-modelsimini','modelsim.ini','-sv','+define+SIM','-work','work') + $rtlSources
    Invoke-CompileTool (Join-Path $resolvedBin 'vlog.exe') $rtlArgs (Join-Path $resultDir 'logs/rtl.compile.log')
    $tbArgs = @('-modelsimini','modelsim.ini','-sv','-work','work') + $benchSources
    Invoke-CompileTool (Join-Path $resolvedBin 'vlog.exe') $tbArgs (Join-Path $resultDir 'logs/testbenches.compile.log')
    $compiled = $true
    foreach ($case in $cases) {
        Write-Host "RUN $($case.Name): $($case.Top) $($case.Generics -join ' ')"
        $runLog = Join-Path $resultDir "logs/$($case.Name).log"
        $commands = [Collections.Generic.List[string]]::new()
        $commands.Add('onerror {quit -f -code 1}')
        $commands.Add('onbreak {quit -f -code 1}')
        if ($case.SaveWave) {
            $signals = @()
            if ($case.Name -eq 'full_system') {
                $signals = @('clk','vclk','rn','rx','tx','local_v','local_ready','local_action','voices','underruns',
                    'playing','recording','guide','overflow','pcm_valid','pl','pr','bc','lr','sd','led',
                    'dut/panic','dut/panic_request','dut/panic_quiescing','dut/panic_discard','dut/audio_rst_n',
                    'dut/cv','dut/cr','dut/co','dut/cs','dut/remote_ev','dut/remote_er','dut/perf_ev','dut/perf_er',
                    'dut/sensor_ev','dut/sensor_er','dut/sensor_pending','dut/watchdog_ev','dut/watchdog_er',
                    'dut/phone_releasing','dut/push_valid','dut/push_ready','dut/push_payload','dut/arb_selected',
                    'dut/cmdv','dut/cmdr','dut/gain','dut/bend','dut/vibrato','dut/fx','dut/synth/state',
                    'dut/fx_valid','dut/fx_ready','dut/fx_l','dut/fx_r','dut/vsample','dut/vl','dut/vr','dut/cdc_drops')
            } elseif ($case.Name -eq 'remote_note_watchdog') {
                $signals = @('clk','rn','hb','expire','acc','on','note','rel','ev','eon','ready','en',
                    'source','vel','timbre','count','offs','released','stalled','stalled_payload',
                    'dut/held','dut/any_held','dut/other_held','dut/held_after_accept_any','dut/silence','dut/scan','dut/event_valid')
            } elseif ($case.Name -eq 'ws2812_matrix') {
                foreach ($instance in @('identity','serpentine','rotated')) {
                    foreach ($signal in @('clk','rst_n','led_data','busy','frame_done','guide_mask','touch_mask','done','frames')) {
                        $signals += "$instance/$signal"
                    }
                }
                $signals += @('identity_done','serpentine_done','rotated_done')
            }
            foreach ($signal in $signals) { $commands.Add('catch {log /' + $case.Top + '/' + $signal + '}') }
        }
        $commands.Add('run -all')
        $commands.Add('quit -f -code 0')
        $commands | Set-Content -LiteralPath (Join-Path $resultDir "cases/$($case.Name).do") -Encoding ASCII
        $simulationArgs = @('-c','-modelsimini','modelsim.ini','-onfinish','exit','-voptargs=+acc',
            '-wlf',"waves/$($case.Name).wlf",'-l',"logs/$($case.Name).log",'-do',"do cases/$($case.Name).do") +
            @($case.Generics) + @('work.' + $case.Top)
        $caseError = $null
        $simResult = $null
        try {
            $caseTimeout = if ($case.Name -eq 'audio_engine_n64') { [Math]::Max($TimeoutSeconds,$AudioLongTimeoutSeconds) } else { $TimeoutSeconds }
            $simResult = Invoke-Simulation $simulationArgs $case.Name $caseTimeout
            $logText = Get-Text $runLog
            if (!$logText) { $logText = Get-Text (Join-Path $resultDir "logs/$($case.Name).console.log") }
            $fatalLines = @([regex]::Matches($logText,'(?im)^\s*#?\s*\*\*\s+Fatal[^\r\n]*') | ForEach-Object Value)
            $errorLines = @([regex]::Matches($logText,'(?im)^\s*#?\s*\*\*\s+Error(?:\s|:)[^\r\n]*') | ForEach-Object Value)
            if ($simResult.TimedOut) { throw "Wall-clock timeout after $caseTimeout seconds" }
            if ($case.ExpectedFatal) {
                # This ModelSim edition can return 0 even for $fatal. The
                # exact DUT failure location/message is the negative oracle.
                if ($simResult.ExitCode -notin @(0,1)) { throw "Unexpected process exit $($simResult.ExitCode)" }
                if ($fatalLines.Count -ne 1 -or $errorLines.Count -ne 0 -or
                    $fatalLines[0] -notmatch ('\*\*\s+Fatal:\s*' + [regex]::Escape($case.ExpectedFatal) + '\s*$') -or
                    $logText -notmatch '(?im)\bTime:\s*0\s+(?:fs|ps|ns|us|ms|sec|s)\b' -or
                    $logText -notmatch ('(?im)\bInstance:\s*/' + [regex]::Escape($case.Top) + '/dut\b') -or
                    $logText -match 'PARAMETER_NOT_REJECTED') {
                    throw 'Missing exact time-zero DUT parameter rejection, or an unrelated simulator error occurred'
                }
            } else {
                if ($simResult.ExitCode -ne 0) { throw "Process exit $($simResult.ExitCode)" }
                if ($fatalLines.Count -ne 0 -or $errorLines.Count -ne 0 -or
                    $logText -match '(?im)\bErrors:\s*[1-9][0-9]*') { throw 'Runtime Error/Fatal found in transcript' }
                if (!$logText.Contains($case.Marker)) { throw "Missing final marker: $($case.Marker)" }
            }
        } catch { $caseError = $_.Exception.Message }
        $passed = !$caseError
        $waveRelative = if ($case.SaveWave) { "waves/$($case.Name).wlf" } else { $null }
        $result = [pscustomobject]@{Name=$case.Name;Top=$case.Top;Generics=$case.Generics;
            ExpectedRejection=[bool]$case.ExpectedFatal;ExpectedMarker=$case.Marker;ExpectedFatal=$case.ExpectedFatal;
            Passed=$passed;ExitCode=if($simResult){$simResult.ExitCode}else{$null};
            TimedOut=if($simResult){$simResult.TimedOut}else{$false};
            ElapsedSeconds=if($simResult){[Math]::Round($simResult.ElapsedSeconds,3)}else{$null};
            TimeoutSeconds=$caseTimeout;
            Log="logs/$($case.Name).log";Wave=$waveRelative;Failure=$caseError}
        $results.Add($result)
        Save-Json (Join-Path $resultDir 'test-summary.json') @($results.ToArray())
        if ($passed) { Write-Host "PASS $($case.Name) ($($result.ElapsedSeconds)s)" }
        else { Write-Host "FAIL $($case.Name): $caseError" }
        if ($passed -and $case.Name -eq 'full_system') {
            $viewerCommand = 'do ' + (Tcl-Quote (Join-Path $resultDir 'sim/view_full_modelsim.do')) + ' ' +
                (Tcl-Quote (Join-Path $resultDir 'waves/full_system.wlf'))
            $viewerCommand | Set-Content -LiteralPath (Join-Path $resultDir 'view_full_system.do') -Encoding ASCII
        }
    }
} catch { $infrastructureError = $_.Exception.Message }
finally {
    foreach ($inputFile in $inputs) {
        if (Test-Path -LiteralPath $inputFile.Source -PathType Leaf) {
            $inputFile.Sha256After = (Get-FileHash -LiteralPath $inputFile.Source -Algorithm SHA256).Hash.ToLowerInvariant()
            $staged = Join-Path $resultDir $inputFile.StagedPath
            $stagedHash = (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash.ToLowerInvariant()
            $inputFile.Unchanged = $inputFile.Sha256Before -eq $inputFile.Sha256After -and $stagedHash -eq $inputFile.Sha256Before
        } else { $inputFile.Unchanged = $false }
        if (!$inputFile.Unchanged) { $unchanged = $false }
    }
    $failedCases = @($results | Where-Object { !$_.Passed })
    $passedCases = @($results | Where-Object Passed)
    $overallPassed = $compiled -and !$infrastructureError -and $unchanged -and
        $failedCases.Count -eq 0 -and $results.Count -eq $cases.Count
    Save-Json (Join-Path $resultDir 'inputs.json') @($inputs.ToArray())
    Save-Json (Join-Path $resultDir 'test-summary.json') @($results.ToArray())
    Save-Json (Join-Path $resultDir 'manifest.json') ([ordered]@{Suite=$Suite;StartedUtc=$startUtc;
        FinishedUtc=[DateTime]::UtcNow.ToString('o');Project=$projectDir;ResultDirectory=$resultDir;
        ModelSimBin=$resolvedBin;VendorModel=$VendorModel;SourceCount=if($rtlSources){$rtlSources.Count}else{0};
        TimeoutSeconds=$TimeoutSeconds;AudioLongTimeoutSeconds=$AudioLongTimeoutSeconds;
        SuiteCaseCount=$suiteCases.Count;FullCaseCount=$allCases.Count;SelectedCaseNames=@($cases.Name);
        Compiled=$compiled;InputsUnchanged=$unchanged;ExpectedCases=$cases.Count;
        PassedCases=$passedCases.Count;FailedCases=$failedCases.Count;Passed=$overallPassed;
        InfrastructureError=$infrastructureError;Cases=@($results.ToArray());Inputs=@($inputs.ToArray());
        Scope='RTL and vendor primitive simulation; no physical hardware test';
        Status=if($overallPassed){'Passed'}else{'Failed'}})
    Pop-Location
}
if (!$overallPassed) {
    throw "ModelSim $Suite regression failed. Passed $($passedCases.Count)/$($cases.Count), inputs unchanged=$unchanged; infrastructure=$infrastructureError. Evidence: $resultDir"
}
Write-Host "ALL MODELSIM $($Suite.ToUpperInvariant()) TESTS PASSED ($($results.Count) cases; original/staged input SHA256 unchanged)."
Write-Host "Evidence: $resultDir"
if ($cases.Name -contains 'full_system') { Write-Host "GUI viewer: do {$(Join-Path $resultDir 'view_full_system.do')}" }
