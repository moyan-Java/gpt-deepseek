$ErrorActionPreference = 'Stop'

$harnessRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$runner = Join-Path $harnessRoot 'dev_tool\agent\Invoke-DeepSeekTask.ps1'
$watch = Join-Path $harnessRoot 'dev_tool\agent\Watch-DeepSeekRun.ps1'
$repair = Join-Path $harnessRoot 'dev_tool\agent\Repair-DeepSeekLock.ps1'

function Get-PowerShellExecutable {
    $pwshCommand = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($null -ne $pwshCommand -and -not [string]::IsNullOrWhiteSpace($pwshCommand.Source)) {
        return $pwshCommand.Source
    }
    $windowsPowerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($null -ne $windowsPowerShell -and -not [string]::IsNullOrWhiteSpace($windowsPowerShell.Source)) {
        return $windowsPowerShell.Source
    }
    throw 'Neither pwsh nor powershell.exe was found on PATH.'
}

function ConvertTo-ProcessArgumentLine([string[]]$Arguments) {
    $quoted = foreach ($argument in $Arguments) {
        $value = [string]$argument
        if ($value -match '[\s"]') {
            '"' + ($value -replace '"', '\"') + '"'
        }
        else {
            $value
        }
    }
    return ($quoted -join ' ')
}

$script:powerShell = Get-PowerShellExecutable
$script:workRoot = Join-Path $harnessRoot 'dev_tool\test\.work'
$script:cleanupPaths = [System.Collections.Generic.List[string]]::new()
$script:passCount = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT: $Message" }
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ("$Actual" -ne "$Expected") {
        throw "ASSERT: $Message (expected '$Expected', got '$Actual')"
    }
}

function Assert-Contains($Collection, [string]$Expected, [string]$Message) {
    if (@($Collection) -notcontains $Expected) {
        throw "ASSERT: $Message (missing '$Expected' in '$(@($Collection) -join ', ')')"
    }
}

function Invoke-ChildScript {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Arguments = @()
    )
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $script:powerShell -NoProfile -File $Path @Arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
    }
}

function New-TestProject {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$TestCommand
    )

    $caseBase = Join-Path $script:workRoot ([guid]::NewGuid().ToString('N'))
    $project = Join-Path $caseBase 'project'
    $control = Join-Path $caseBase 'control'
    $tools = Join-Path $caseBase 'tools'
    New-Item -ItemType Directory -Force -Path $project | Out-Null
    New-Item -ItemType Directory -Force -Path $control | Out-Null
    New-Item -ItemType Directory -Force -Path $tools | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $project 'src') | Out-Null

    $taskText = @"
# Test task: $TaskId

Task-ID: $TaskId
Task-Status: ready
Test-Command: $TestCommand

## Goal

Exercise one finite harness scenario.

## Allowed paths

- src/

## Prohibited actions

- Do not touch files outside src/.

## Acceptance criteria

- The run leaves RESULT.json.
"@
    Set-Content -LiteralPath (Join-Path $control 'TASK.md') -Value $taskText -Encoding utf8

    $milestoneText = @'
# Test milestone

## Predeclared boundary

One finite test run.

## Stop rules

Stop on failures.
'@
    Set-Content -LiteralPath (Join-Path $control 'MILESTONE.md') -Value $milestoneText -Encoding utf8

    $fakeDsh = @'
$allArgs = $args -join ' '
if ($allArgs -match '--help') {
    Write-Output 'fake dsh help'
    exit 0
}
$null = [Console]::In.ReadToEnd()
$logPath = $env:FAKE_DSH_LOG
if ($logPath) { Add-Content -LiteralPath $logPath -Value 'invoked' -Encoding utf8 }
$mode = $env:FAKE_DSH_MODE
switch ($mode) {
    'success' {
        Set-Content -LiteralPath (Join-Path (Get-Location) 'src\ok.txt') -Value 'ok' -Encoding utf8
        [Console]::Out.WriteLine('{"event":"EVENT_SECRET_MARKER"}')
        [Console]::Error.WriteLine('STDERR_SECRET_MARKER')
        exit 0
    }
    'model-failure' {
        [Console]::Out.WriteLine('{"event":"EVENT_SECRET_MARKER"}')
        [Console]::Error.WriteLine('STDERR_SECRET_MARKER')
        exit 7
    }
    'scope-failure' {
        Set-Content -LiteralPath (Join-Path (Get-Location) 'outside.txt') -Value 'outside' -Encoding utf8
        [Console]::Out.WriteLine('{"event":"EVENT_SECRET_MARKER"}')
        exit 0
    }
    'test-failure' {
        Set-Content -LiteralPath (Join-Path (Get-Location) 'src\ok.txt') -Value 'ok' -Encoding utf8
        exit 0
    }
    'stream-gate' {
        [Console]::Out.WriteLine('{"event":"STREAM_FIRST"}')
        [Console]::Error.WriteLine('STREAM_ERR_FIRST')
        [Console]::Out.Flush()
        [Console]::Error.Flush()
        $gate = $env:FAKE_DSH_GATE
        if ([string]::IsNullOrWhiteSpace($gate)) { exit 12 }
        while (-not (Test-Path -LiteralPath $gate)) { Start-Sleep -Milliseconds 100 }
        Set-Content -LiteralPath (Join-Path (Get-Location) 'src\ok.txt') -Value 'ok' -Encoding utf8
        [Console]::Out.WriteLine('{"event":"STREAM_SECOND"}')
        [Console]::Error.WriteLine('STREAM_ERR_SECOND')
        [Console]::Out.Flush()
        [Console]::Error.Flush()
        exit 0
    }
    default {
        exit 3
    }
}
'@
    $dshPath = Join-Path $tools 'fake-dsh.ps1'
    Set-Content -LiteralPath $dshPath -Value $fakeDsh -Encoding utf8

    $fakeCodex = @'
$allArgs = @($args)
$message = ''
for ($i = 0; $i -lt $allArgs.Count; $i++) {
    if ($allArgs[$i] -eq '--message' -and ($i + 1) -lt $allArgs.Count) {
        $message = [string]$allArgs[$i + 1]
    }
}
$resultPath = $null
if ($message -match 'recorded at (.+?RESULT\.json)') {
    $resultPath = $Matches[1].Trim()
}
$resultExists = $false
if ($null -ne $resultPath) { $resultExists = Test-Path -LiteralPath $resultPath }
$reportExists = $false
if ($resultExists) {
    $controlRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $resultPath))
    $reportExists = Test-Path -LiteralPath (Join-Path $controlRoot 'REPORT.md')
}
$entry = [ordered]@{
    message = $message
    argument_count = $allArgs.Count
    report_exists = $reportExists
    result_exists = $resultExists
}
$logPath = $env:FAKE_CODEX_LOG
if ($logPath) { Add-Content -LiteralPath $logPath -Value ($entry | ConvertTo-Json -Compress) -Encoding utf8 }
exit [int]$env:FAKE_CODEX_EXIT
'@
    $codexPath = Join-Path $tools 'fake-codex.ps1'
    Set-Content -LiteralPath $codexPath -Value $fakeCodex -Encoding utf8

    $fakeMonitor = @'
$allArgs = @($args)
$runDirectory = ''
for ($i = 0; $i -lt $allArgs.Count; $i++) {
    if ($allArgs[$i] -eq '-RunDirectory' -and ($i + 1) -lt $allArgs.Count) {
        $runDirectory = [string]$allArgs[$i + 1]
    }
}
$runDirectoryExists = $false
$eventsExists = $false
$stderrExists = $false
$resultExists = $false
if (-not [string]::IsNullOrWhiteSpace($runDirectory)) {
    $runDirectoryExists = Test-Path -LiteralPath $runDirectory -PathType Container
    $eventsExists = Test-Path -LiteralPath (Join-Path $runDirectory 'events.jsonl') -PathType Leaf
    $stderrExists = Test-Path -LiteralPath (Join-Path $runDirectory 'stderr.log') -PathType Leaf
    $resultExists = Test-Path -LiteralPath (Join-Path $runDirectory 'RESULT.json') -PathType Leaf
}
$entry = [ordered]@{
    args = $allArgs
    run_directory = $runDirectory
    run_directory_exists = $runDirectoryExists
    events_exists = $eventsExists
    stderr_exists = $stderrExists
    result_exists = $resultExists
    current_directory = (Get-Location).Path
}
$logPath = $env:FAKE_MONITOR_LOG
if ($logPath) { Add-Content -LiteralPath $logPath -Value ($entry | ConvertTo-Json -Compress) -Encoding utf8 }
exit 0
'@
    $monitorPath = Join-Path $tools 'fake-monitor.ps1'
    Set-Content -LiteralPath $monitorPath -Value $fakeMonitor -Encoding utf8

    $script:cleanupPaths.Add($caseBase)
    return [pscustomobject]@{
        Root = $control
        TargetRoot = $project
        Tools = $tools
        TaskId = $TaskId
        DshPath = $dshPath
        CodexPath = $codexPath
        MonitorPath = $monitorPath
        DshLog = (Join-Path $tools 'dsh-calls.log')
        CodexLog = (Join-Path $tools 'codex-calls.log')
        MonitorLog = (Join-Path $tools 'monitor-calls.log')
    }
}

function Set-FakeEnvironment {
    param(
        [Parameter(Mandatory)]$Case,
        [Parameter(Mandatory)][string]$DshMode,
        [int]$CodexExit = 0
    )
    $env:FAKE_DSH_MODE = $DshMode
    $env:FAKE_DSH_LOG = $Case.DshLog
    $env:FAKE_DSH_GATE = ''
    $env:FAKE_CODEX_LOG = $Case.CodexLog
    $env:FAKE_CODEX_EXIT = [string]$CodexExit
    $env:FAKE_MONITOR_LOG = $Case.MonitorLog
    if (Test-Path -LiteralPath $Case.DshLog) { Remove-Item -LiteralPath $Case.DshLog -Force }
    if (Test-Path -LiteralPath $Case.CodexLog) { Remove-Item -LiteralPath $Case.CodexLog -Force }
    if (Test-Path -LiteralPath $Case.MonitorLog) { Remove-Item -LiteralPath $Case.MonitorLog -Force }
}

function Get-HarnessArguments {
    param(
        [Parameter(Mandatory)]$Case,
        [string]$Thread,
        [switch]$RunTests,
        [switch]$DryRun,
        [switch]$OpenMonitor,
        [string]$MonitorScriptPath,
        [string]$MonitorWindowStyle
    )
    $arguments = @(
        '-NoProfile',
        '-File', $runner,
        '-ProjectRoot', $Case.TargetRoot,
        '-ControlRoot', $Case.Root,
        '-DshPath', $Case.DshPath,
        '-CodexPath', $Case.CodexPath
    )
    if (-not [string]::IsNullOrWhiteSpace($Thread)) { $arguments += @('-CodexThread', $Thread) }
    if ($RunTests) { $arguments += '-RunTests' }
    if ($DryRun) { $arguments += '-DryRun' }
    if ($OpenMonitor) {
        $arguments += '-OpenMonitor'
        if (-not [string]::IsNullOrWhiteSpace($MonitorScriptPath)) {
            $arguments += @('-MonitorScriptPath', $MonitorScriptPath)
        }
        if (-not [string]::IsNullOrWhiteSpace($MonitorWindowStyle)) {
            $arguments += @('-MonitorWindowStyle', $MonitorWindowStyle)
        }
    }
    return $arguments
}

function Invoke-Harness {
    param(
        [Parameter(Mandatory)]$Case,
        [string]$Thread,
        [switch]$RunTests,
        [switch]$DryRun,
        [switch]$OpenMonitor,
        [string]$MonitorScriptPath,
        [string]$MonitorWindowStyle
    )
    $arguments = Get-HarnessArguments -Case $Case -Thread $Thread -RunTests:$RunTests -DryRun:$DryRun -OpenMonitor:$OpenMonitor -MonitorScriptPath $MonitorScriptPath -MonitorWindowStyle $MonitorWindowStyle
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # Failed harness cases are test inputs. Preserve their non-zero exit code
        # and output so assertions can inspect RESULT.json afterwards.
        $output = & $script:powerShell @arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
    }
}

function Start-Harness {
    param(
        [Parameter(Mandatory)]$Case,
        [string]$Thread,
        [switch]$RunTests,
        [switch]$DryRun,
        [switch]$OpenMonitor,
        [string]$MonitorScriptPath,
        [string]$MonitorWindowStyle
    )
    $arguments = Get-HarnessArguments -Case $Case -Thread $Thread -RunTests:$RunTests -DryRun:$DryRun -OpenMonitor:$OpenMonitor -MonitorScriptPath $MonitorScriptPath -MonitorWindowStyle $MonitorWindowStyle
    $argumentLine = ConvertTo-ProcessArgumentLine -Arguments $arguments
    $stdoutPath = Join-Path $Case.Tools 'harness-stdout.log'
    $stderrPath = Join-Path $Case.Tools 'harness-stderr.log'
    $process = Start-Process -FilePath $script:powerShell -ArgumentList $argumentLine -WorkingDirectory $harnessRoot -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    return [pscustomobject]@{
        Process = $process
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
    }
}

function Get-BackgroundOutput {
    param([Parameter(Mandatory)]$Background)
    return ((Get-TextSnapshot -Path $Background.StdoutPath) + [Environment]::NewLine + (Get-TextSnapshot -Path $Background.StderrPath))
}

function Wait-Until {
    param(
        [Parameter(Mandatory)][scriptblock]$Condition,
        [int]$TimeoutSeconds = 20,
        [string]$Description = 'condition'
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            if (& $Condition) { return }
        }
        catch { }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for $Description."
}

function Wait-ProcessExit {
    param(
        [Parameter(Mandatory)]$Process,
        [int]$TimeoutSeconds = 30,
        [string]$Description = 'process'
    )
    if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $Process.Kill() } catch { }
        throw "Timed out waiting for $Description."
    }
    $Process.Refresh()
}

function Get-RunDirectories {
    param([Parameter(Mandatory)][string]$Root)
    $runsPath = Join-Path $Root 'runs'
    if (-not (Test-Path -LiteralPath $runsPath -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $runsPath -Directory -ErrorAction SilentlyContinue)
}

function Get-TextSnapshot {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
            try {
                return $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        return ''
    }
}

function Get-FileHashSafe {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-SingleRunResult {
    param([Parameter(Mandatory)][string]$Root)
    $runsPath = Join-Path $Root 'runs'
    Assert-True (Test-Path -LiteralPath $runsPath) "Run directory is missing under $runsPath"
    $runDirs = @(Get-ChildItem -LiteralPath $runsPath -Directory | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'RESULT.json')
    })
    Assert-Equal $runDirs.Count 1 "Expected one run directory with RESULT.json under $runsPath"
    $runDirectory = $runDirs[0].FullName
    $resultPath = Join-Path $runDirectory 'RESULT.json'
    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    return [pscustomobject]@{
        Directory = $runDirectory
        Path = $resultPath
        Result = $result
    }
}

function Get-JsonLines {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $items = @()
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $items += ($line | ConvertFrom-Json)
    }
    return $items
}

function Get-LineCount {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    return @(Get-Content -LiteralPath $Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
}

try {
    if (-not (Test-Path -LiteralPath $runner)) { throw 'Harness runner is missing.' }
    if (-not (Test-Path -LiteralPath $watch)) { throw 'Run monitor is missing.' }
    if (-not (Test-Path -LiteralPath $repair)) { throw 'Stale-lock recovery command is missing.' }

    New-Item -ItemType Directory -Force -Path $script:workRoot | Out-Null

    # 1. Dry-run verification with a fake executable (no model call).
    $dryCase = New-TestProject -TaskId 'test-dry-run' -TestCommand 'Write-Output ok; exit 0'
    Set-FakeEnvironment -Case $dryCase -DshMode 'success'
    $dry = Invoke-Harness -Case $dryCase -DryRun
    Assert-Equal $dry.ExitCode 0 "Harness dry run failed: $($dry.Output)"
    $dryReportPath = Join-Path $dryCase.Root 'REPORT.md'
    $reportText = Get-Content -LiteralPath $dryReportPath -Raw
    Assert-True ($reportText -match 'Result: dry-run') 'Dry-run report was not written.'
    Assert-Equal (Get-LineCount -Path $dryCase.DshLog) 0 'Dry run must not invoke the model.'
    Write-Output 'PASS: dry-run verification without invoking a model.'
    $script:passCount++

    # 2. Successful run with no queue request.
    $case = New-TestProject -TaskId 'test-success' -TestCommand 'Write-Output ok; exit 0'
    Set-FakeEnvironment -Case $case -DshMode 'success'
    $run = Invoke-Harness -Case $case -RunTests
    $bundle = Get-SingleRunResult -Root $case.Root
    Assert-Equal $run.ExitCode 0 "Successful run returned $($run.ExitCode): $($run.Output)"
    Assert-Equal $bundle.Result.task_id $case.TaskId 'RESULT.json has the wrong task id.'
    Assert-Equal $bundle.Result.terminal_status 'passed' 'Successful run must be passed.'
    Assert-Equal $bundle.Result.model_exit_code 0 'Model exit code was not recorded.'
    Assert-Contains $bundle.Result.changed_paths 'src/ok.txt' 'Changed path was not recorded.'
    Assert-True ($bundle.Result.scope_result.valid -eq $true) 'Successful in-scope run marked invalid.'
    Assert-Equal $bundle.Result.test_exit_code 0 'Test exit code was not recorded.'
    Assert-True (Test-Path -LiteralPath $bundle.Result.report_path) 'Report path does not exist.'
    Assert-Equal $bundle.Result.delivery_state 'not_requested' 'No thread must mean not_requested.'
    Assert-True (-not [string]::IsNullOrWhiteSpace($bundle.Result.next_action)) 'Next action is missing.'
    Assert-True (Test-Path -LiteralPath (Join-Path $bundle.Directory 'events.jsonl')) 'events.jsonl is missing.'
    Assert-True (Test-Path -LiteralPath (Join-Path $bundle.Directory 'stderr.log')) 'stderr.log is missing.'
    Assert-True (-not (Test-Path -LiteralPath $case.MonitorLog)) 'A normal run must not launch a monitor process.'
    Write-Output 'PASS: successful run writes RESULT.json without a queue request or monitor.'
    $script:passCount++

    # 3. Model failure.
    $case = New-TestProject -TaskId 'test-model-failure' -TestCommand 'Write-Output should-not-run; exit 0'
    Set-FakeEnvironment -Case $case -DshMode 'model-failure'
    $run = Invoke-Harness -Case $case -RunTests
    $bundle = Get-SingleRunResult -Root $case.Root
    Assert-True ($run.ExitCode -ne 0) 'Model failure must return a nonzero exit code.'
    Assert-Equal $bundle.Result.terminal_status 'failed' 'Model failure must be failed.'
    Assert-Equal $bundle.Result.model_exit_code 7 'Model exit code was not recorded.'
    Assert-Equal $bundle.Result.test_exit_code -1 'Tests must not run after model failure.'
    Assert-Equal $bundle.Result.delivery_state 'not_requested' 'Model failure without a thread must be not_requested.'
    Write-Output 'PASS: model failure leaves a failed RESULT.json.'
    $script:passCount++

    # 4. Test failure after a successful model run.
    $case = New-TestProject -TaskId 'test-test-failure' -TestCommand 'Write-Output test-failure; exit 9'
    Set-FakeEnvironment -Case $case -DshMode 'test-failure'
    $run = Invoke-Harness -Case $case -RunTests
    $bundle = Get-SingleRunResult -Root $case.Root
    Assert-True ($run.ExitCode -ne 0) 'Test failure must return a nonzero exit code.'
    Assert-Equal $bundle.Result.terminal_status 'failed' 'Test failure must be failed.'
    Assert-Equal $bundle.Result.model_exit_code 0 'Model should have succeeded.'
    Assert-Equal $bundle.Result.test_exit_code 9 'Test exit code was not recorded.'
    Assert-True ($bundle.Result.scope_result.valid -eq $true) 'Scope should still be valid.'
    Write-Output 'PASS: test failure leaves a failed RESULT.json.'
    $script:passCount++

    # 5. Scope failure.
    $case = New-TestProject -TaskId 'test-scope-failure' -TestCommand 'Write-Output should-not-run; exit 0'
    Set-FakeEnvironment -Case $case -DshMode 'scope-failure'
    $run = Invoke-Harness -Case $case -RunTests
    $bundle = Get-SingleRunResult -Root $case.Root
    Assert-True ($run.ExitCode -ne 0) 'Scope failure must return a nonzero exit code.'
    Assert-Equal $bundle.Result.terminal_status 'failed' 'Scope failure must be failed.'
    Assert-True ($bundle.Result.scope_result.valid -eq $false) 'Scope failure must mark the scope invalid.'
    Assert-Contains $bundle.Result.scope_result.out_of_scope 'outside.txt' 'Out-of-scope path was not recorded.'
    Assert-Equal $bundle.Result.test_exit_code -1 'Tests must not run after a scope failure.'
    Write-Output 'PASS: scope failure is recorded in RESULT.json.'
    $script:passCount++

    # 6. Queue success.
    $case = New-TestProject -TaskId 'test-queue-success' -TestCommand 'Write-Output ok; exit 0'
    Set-FakeEnvironment -Case $case -DshMode 'success' -CodexExit 0
    $run = Invoke-Harness -Case $case -Thread 'thread-success' -RunTests
    $bundle = Get-SingleRunResult -Root $case.Root
    Assert-Equal $run.ExitCode 0 "Queue success run returned $($run.ExitCode): $($run.Output)"
    Assert-Equal $bundle.Result.terminal_status 'passed' 'Queue success run must be passed.'
    Assert-Equal $bundle.Result.delivery_state 'queued' 'Queue success must be queued.'
    Assert-Equal $bundle.Result.delivery.queue_exit_code 0 'Queue exit code was not recorded.'
    $codexCalls = @(Get-JsonLines -Path $case.CodexLog)
    Assert-Equal $codexCalls.Count 1 'Exactly one Codex queue call was expected.'
    Assert-Equal (Get-LineCount -Path $case.DshLog) 1 'DeepSeek must run exactly once.'
    $message = [string]$codexCalls[0].message
    Assert-True ($message.Contains($bundle.Path)) 'Queue message must contain the RESULT.json path.'
    Assert-True ($message.Length -le 1200) 'Queue message exceeds the bounded instruction limit.'
    Assert-True ($message -notmatch 'EVENT_SECRET_MARKER') 'Queue message leaked event output.'
    Assert-True ($message -notmatch 'STDERR_SECRET_MARKER') 'Queue message leaked stderr output.'
    Assert-True ($codexCalls[0].report_exists -eq $true) 'Report was not generated before the queue call.'
    Assert-True ($codexCalls[0].result_exists -eq $true) 'RESULT.json was not generated before the queue call.'
    Assert-True ($message -match '(?i)interactive host') 'Queue instruction must mention interactive-host stop conditions.'
    Assert-True ($message -match '(?i)milestone') 'Queue instruction must mention milestone completion.'
    Assert-True ($message -match '(?i)out-of-scope') 'Queue instruction must mention out-of-scope changes.'
    Assert-True (Test-Path -LiteralPath (Join-Path $bundle.Directory 'codex-message.txt')) 'Review message was not saved.'
    Write-Output 'PASS: queue success sends one bounded RESULT-only review request.'
    $script:passCount++

    # 7. Queue failure does not rerun DeepSeek.
    $case = New-TestProject -TaskId 'test-queue-failure' -TestCommand 'Write-Output ok; exit 0'
    Set-FakeEnvironment -Case $case -DshMode 'success' -CodexExit 5
    $run = Invoke-Harness -Case $case -Thread 'thread-queue-failure' -RunTests
    $bundle = Get-SingleRunResult -Root $case.Root
    Assert-True ($run.ExitCode -ne 0) 'Queue failure must return a nonzero exit code.'
    Assert-True (Test-Path -LiteralPath $bundle.Path) 'Queue failure must leave RESULT.json.'
    Assert-Equal $bundle.Result.terminal_status 'passed' 'Delegation itself passed before the queue failure.'
    Assert-Equal $bundle.Result.delivery_state 'failed' 'Queue failure must be recorded as failed delivery.'
    Assert-Equal $bundle.Result.delivery.queue_exit_code 5 'Queue exit code was not recorded.'
    $failedQueueCalls = @(Get-JsonLines -Path $case.CodexLog)
    Assert-Equal $failedQueueCalls.Count 1 'Exactly one Codex queue attempt was expected.'
    Assert-Equal (Get-LineCount -Path $case.DshLog) 1 'DeepSeek must not be rerun after a queue failure.'
    Write-Output 'PASS: queue failure retains RESULT.json and does not rerun DeepSeek.'
    $script:passCount++

    # 8. Live streaming plus one test-seam monitor launch.
    $case = New-TestProject -TaskId 'test-stream-monitor' -TestCommand 'Write-Output ok; exit 0'
    Set-FakeEnvironment -Case $case -DshMode 'stream-gate'
    $gatePath = Join-Path $case.Tools 'stream.gate'
    $env:FAKE_DSH_GATE = $gatePath
    $bg = Start-Harness -Case $case -OpenMonitor -MonitorScriptPath $case.MonitorPath -MonitorWindowStyle 'Hidden'
    try {
        Wait-Until -TimeoutSeconds 30 -Description 'streamed STREAM_FIRST event' -Condition {
            $runs = @(Get-RunDirectories -Root $case.Root)
            if ($runs.Count -ne 1) { return $false }
            $eventFile = Join-Path $runs[0].FullName 'events.jsonl'
            $text = Get-TextSnapshot -Path $eventFile
            return $text.Contains('STREAM_FIRST')
        }
        $runDirectories = @(Get-RunDirectories -Root $case.Root)
        Assert-Equal $runDirectories.Count 1 'Expected one live run directory.'
        $runDirectory = $runDirectories[0].FullName
        Assert-True (-not $bg.Process.HasExited) 'Harness exited before the child was released; streaming was not live.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $runDirectory 'RESULT.json'))) 'RESULT.json appeared before the child completed.'
        $eventsNow = Get-TextSnapshot -Path (Join-Path $runDirectory 'events.jsonl')
        $stderrNow = Get-TextSnapshot -Path (Join-Path $runDirectory 'stderr.log')
        Assert-True ($eventsNow.Contains('STREAM_FIRST')) 'The first JSON event was not visible while the child was alive.'
        Assert-True ($stderrNow.Contains('STREAM_ERR_FIRST')) 'The first stderr line was not visible while the child was alive.'

        Wait-Until -TimeoutSeconds 20 -Description 'monitor launch record' -Condition {
            if (-not (Test-Path -LiteralPath $case.MonitorLog)) { return $false }
            try { return (@(Get-JsonLines -Path $case.MonitorLog).Count -ge 1) }
            catch { return $false }
        }
        $monitorCalls = @(Get-JsonLines -Path $case.MonitorLog)
        Assert-Equal $monitorCalls.Count 1 'Exactly one monitor process must be launched.'
        Assert-Equal $monitorCalls[0].run_directory $runDirectory 'The monitor must be scoped to the current run.'
        Assert-True ($monitorCalls[0].run_directory_exists -eq $true) 'The monitor must start after the run directory exists.'
        Assert-True ($monitorCalls[0].events_exists -eq $true) 'The monitor must start after events.jsonl exists.'
        Assert-True ($monitorCalls[0].stderr_exists -eq $true) 'The monitor must start after stderr.log exists.'
        Assert-True ($monitorCalls[0].result_exists -eq $false) 'The monitor must start before the run is complete.'
        $monitorArguments = @($monitorCalls[0].args) -join ' '
        Assert-True ($monitorArguments.Contains('-RunDirectory')) 'The monitor was not given a run directory argument.'
        Assert-True ($monitorArguments.Contains('-Follow')) 'The monitor was not started in follow mode.'

        Set-Content -LiteralPath $gatePath -Value 'release' -Encoding utf8
        Wait-ProcessExit -Process $bg.Process -TimeoutSeconds 30 -Description 'harness after releasing the streamed child'
        $backgroundOutput = Get-BackgroundOutput -Background $bg
        Assert-True ($backgroundOutput -notmatch 'Delegation failed') "Streaming run failed: $backgroundOutput"
    }
    finally {
        if (-not (Test-Path -LiteralPath $gatePath)) {
            Set-Content -LiteralPath $gatePath -Value 'release' -Encoding utf8
        }
        if (-not $bg.Process.HasExited) {
            try { $bg.Process.Kill() } catch { }
        }
        Remove-Item Env:FAKE_DSH_GATE -ErrorAction SilentlyContinue
    }

    $bundle = Get-SingleRunResult -Root $case.Root
    $eventObjects = @(Get-JsonLines -Path (Join-Path $bundle.Directory 'events.jsonl'))
    Assert-Equal $eventObjects.Count 2 'Both streamed JSON events should be retained.'
    Assert-True (@($eventObjects | Where-Object { $_.event -eq 'STREAM_FIRST' }).Count -eq 1) 'STREAM_FIRST was not retained.'
    Assert-True (@($eventObjects | Where-Object { $_.event -eq 'STREAM_SECOND' }).Count -eq 1) 'STREAM_SECOND was not retained.'
    $monitorCalls = @(Get-JsonLines -Path $case.MonitorLog)
    Assert-Equal $monitorCalls.Count 1 'The run must launch exactly one monitor process.'
    Assert-Equal (Get-LineCount -Path $case.DshLog) 1 'DeepSeek must run exactly once in the streaming case.'

    $eventsHash = Get-FileHashSafe -Path (Join-Path $bundle.Directory 'events.jsonl')
    $stderrHash = Get-FileHashSafe -Path (Join-Path $bundle.Directory 'stderr.log')
    $follow = Invoke-ChildScript -Path $watch -Arguments @('-RunDirectory', $bundle.Directory, '-Follow', '-FollowTimeoutSeconds', '10')
    Assert-Equal $follow.ExitCode 0 "Terminal monitor follow failed: $($follow.Output)"
    $progressCount = ([regex]::Matches($follow.Output, '【DeepSeek 执行】收到一条运行事件。')).Count
    Assert-True ($progressCount -ge 2) '监视器没有显示中文运行摘要。'
    Assert-True (-not $follow.Output.Contains('STREAM_FIRST')) '监视器泄露了原始事件内容。'
    Assert-True (-not $follow.Output.Contains('STREAM_ERR_FIRST')) '监视器泄露了原始诊断内容。'
    Assert-True ($follow.Output.Contains('已记录 2 条诊断信息')) '监视器没有说明诊断信息已被隐藏。'
    Assert-True ($follow.Output.Contains('【系统验收】')) '监视器没有显示中文验收区块。'
    Assert-True ($follow.Output.Contains('最终状态：成功')) '监视器没有显示中文最终状态。'
    Assert-Equal (Get-FileHashSafe -Path (Join-Path $bundle.Directory 'events.jsonl')) $eventsHash 'The monitor modified events.jsonl.'
    Assert-Equal (Get-FileHashSafe -Path (Join-Path $bundle.Directory 'stderr.log')) $stderrHash 'The monitor modified stderr.log.'
    Assert-Equal (Get-LineCount -Path $case.DshLog) 1 'The monitor must not invoke DeepSeek.'
    Assert-True (-not (Test-Path -LiteralPath $case.CodexLog)) 'The monitor must not invoke Codex.'
    Write-Output 'PASS: events stream live, one monitor is launched, and follow mode shows the terminal result read-only.'
    $script:passCount++

    # 9. Verified stale-lock recovery.
    $case = New-TestProject -TaskId 'test-stale-lock' -TestCommand 'Write-Output ok; exit 0'
    $lockDirectory = Join-Path $case.Root 'run.lock'
    New-Item -ItemType Directory -Force -Path $lockDirectory | Out-Null
    $staleOwner = [ordered]@{
        pid = 999999
        process_started_at = (Get-Date).AddHours(-2).ToString('o')
        started_at = (Get-Date).AddHours(-2).ToString('o')
        token = 'stale-token'
        task_id = 'test-stale-lock'
    }
    $staleOwner | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $lockDirectory 'owner.json') -Encoding utf8
    $recoveryRun = Invoke-ChildScript -Path $repair -Arguments @('-ProjectRoot', $case.TargetRoot, '-ControlRoot', $case.Root)
    Assert-Equal $recoveryRun.ExitCode 0 "Stale-lock recovery failed: $($recoveryRun.Output)"
    Assert-True (-not (Test-Path -LiteralPath $lockDirectory)) 'Stale lock was not cleared.'
    $archiveRoot = Join-Path $case.Root 'runs\stale-locks'
    $archives = @(Get-ChildItem -LiteralPath $archiveRoot -Directory)
    Assert-Equal $archives.Count 1 'Stale lock evidence was not archived.'
    Assert-True (Test-Path -LiteralPath (Join-Path $archives[0].FullName 'run.lock\owner.json')) 'Archived owner.json is missing.'
    $recoveryPath = Join-Path $archives[0].FullName 'recovery.json'
    Assert-True (Test-Path -LiteralPath $recoveryPath) 'Recovery evidence is missing.'
    $recovery = Get-Content -LiteralPath $recoveryPath -Raw | ConvertFrom-Json
    Assert-Equal $recovery.verification.owner_pid 999999 'Recovery evidence has the wrong owner pid.'
    $recordedDshProcesses = @($recovery.verification.dsh_processes | Where-Object { $null -ne $_ })
    Assert-Equal $recordedDshProcesses.Count 0 'Recovery evidence should record no DeepSeek process.'
    Write-Output 'PASS: verified stale lock is archived with evidence.'
    $script:passCount++

    # 10. Recovery refuses a live owner.
    $case = New-TestProject -TaskId 'test-live-lock' -TestCommand 'Write-Output ok; exit 0'
    $lockDirectory = Join-Path $case.Root 'run.lock'
    New-Item -ItemType Directory -Force -Path $lockDirectory | Out-Null
    $liveOwner = [ordered]@{
        pid = $PID
        process_started_at = (Get-Process -Id $PID).StartTime.ToString('o')
        started_at = (Get-Date).ToString('o')
        token = 'live-token'
        task_id = 'test-live-lock'
    }
    $liveOwner | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $lockDirectory 'owner.json') -Encoding utf8
    $refusal = Invoke-ChildScript -Path $repair -Arguments @('-ProjectRoot', $case.TargetRoot, '-ControlRoot', $case.Root)
    Assert-True ($refusal.ExitCode -ne 0) 'Recovery must refuse a live owner.'
    Assert-True ($refusal.Output -match '(?i)owner process') 'Recovery must identify the live owner.'
    Assert-True (Test-Path -LiteralPath $lockDirectory) 'Recovery must leave a live-owner lock in place.'
    Assert-True (Test-Path -LiteralPath (Join-Path $lockDirectory 'owner.json')) 'Recovery must retain live-owner evidence.'
    Write-Output 'PASS: recovery refuses a live owner.'
    $script:passCount++

    # 11. Recovery refuses a matching DeepSeek process.
    $case = New-TestProject -TaskId 'test-dsh-lock' -TestCommand 'Write-Output ok; exit 0'
    $lockDirectory = Join-Path $case.Root 'run.lock'
    New-Item -ItemType Directory -Force -Path $lockDirectory | Out-Null
    $deadOwner = [ordered]@{
        pid = 999999
        process_started_at = (Get-Date).AddHours(-2).ToString('o')
        started_at = (Get-Date).AddHours(-2).ToString('o')
        token = 'dsh-token'
        task_id = 'test-dsh-lock'
    }
    $deadOwner | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $lockDirectory 'owner.json') -Encoding utf8
    $probe = Start-Process -FilePath $script:powerShell -ArgumentList @(
        '-NoProfile',
        '-Command',
        'Start-Sleep -Seconds 60 # dsh headless probe'
    ) -PassThru -WindowStyle Hidden
    try {
        Start-Sleep -Milliseconds 750
        $refusal = Invoke-ChildScript -Path $repair -Arguments @('-ProjectRoot', $case.TargetRoot, '-ControlRoot', $case.Root)
        Assert-True ($refusal.ExitCode -ne 0) 'Recovery must refuse while a matching DeepSeek process is running.'
        Assert-True ($refusal.Output -match '(?i)matching DeepSeek process') 'Recovery must identify the matching DeepSeek process.'
        Assert-True (Test-Path -LiteralPath $lockDirectory) 'Recovery must leave the lock in place during a DeepSeek process.'
    }
    finally {
        if ($null -ne $probe -and -not $probe.HasExited) {
            Stop-Process -Id $probe.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Output 'PASS: recovery refuses while a matching DeepSeek process is running.'
    $script:passCount++

    Write-Output "All harness checks passed ($($script:passCount) checks)."
}
finally {
    foreach ($path in @($script:cleanupPaths)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $resolved = [System.IO.Path]::GetFullPath($path)
        $workResolved = [System.IO.Path]::GetFullPath($script:workRoot).TrimEnd('\')
        $workPrefix = $workResolved + '\'
        if ($resolved.StartsWith($workPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $resolved)) {
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
