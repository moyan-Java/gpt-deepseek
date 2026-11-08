[CmdletBinding()]
param(
    [ValidateSet('workspace-write')]
    [string]$PermissionMode = 'workspace-write',

    [ValidateSet('ask', 'never')]
    [string]$ApprovalPolicy = 'ask',

    [string]$CodexThread,

    [string]$DshPath,

    [string]$CodexPath,

    [Parameter(Mandatory)]
    [string]$ProjectRoot,

    [Parameter(Mandatory)]
    [string]$ControlRoot,

    [switch]$RunTests,
    [switch]$Follow,
    [switch]$OpenMonitor,
    [string]$MonitorScriptPath,
    [ValidateSet('Normal', 'Hidden', 'Minimized')]
    [string]$MonitorWindowStyle = 'Normal',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$projectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$controlRoot = [System.IO.Path]::GetFullPath($ControlRoot)
if (-not (Test-Path -LiteralPath $projectRoot -PathType Container)) {
    throw "ProjectRoot does not exist: $projectRoot"
}
if (-not (Test-Path -LiteralPath $controlRoot -PathType Container)) {
    throw "ControlRoot does not exist: $controlRoot"
}
$taskPath = Join-Path $controlRoot 'TASK.md'
$reportPath = Join-Path $controlRoot 'REPORT.md'
$milestonePath = Join-Path $controlRoot 'MILESTONE.md'
$lockDirectory = Join-Path $controlRoot 'run.lock'
$lockOwnerPath = Join-Path $lockDirectory 'owner.json'
$reviewInstructionLimit = 1200

function Get-PowerShellPath {
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
        if ($value.Length -eq 0) {
            '""'
            continue
        }
        if ($value -notmatch '[\s"]') {
            $value
            continue
        }

        $builder = [System.Text.StringBuilder]::new()
        [void]$builder.Append('"')
        $backslashes = 0
        foreach ($character in $value.ToCharArray()) {
            if ($character -eq '\') {
                $backslashes++
                continue
            }
            if ($character -eq '"') {
                [void]$builder.Append(('\' * ($backslashes * 2 + 1)))
                [void]$builder.Append('"')
                $backslashes = 0
                continue
            }
            if ($backslashes -gt 0) {
                [void]$builder.Append(('\' * $backslashes))
                $backslashes = 0
            }
            [void]$builder.Append($character)
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * ($backslashes * 2)))
        }
        [void]$builder.Append('"')
        $builder.ToString()
    }
    return ($quoted -join ' ')
}

function Start-RunMonitor([string]$RunDirectory, [string]$MonitorScript, [string]$WindowStyle) {
    $usesDefaultMonitor = [string]::IsNullOrWhiteSpace($MonitorScript)
    $monitorPath = if ([string]::IsNullOrWhiteSpace($MonitorScript)) {
        Join-Path $PSScriptRoot 'Watch-DeepSeekRun.ps1'
    }
    elseif ([System.IO.Path]::IsPathRooted($MonitorScript)) {
        [System.IO.Path]::GetFullPath($MonitorScript)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $projectRoot $MonitorScript))
    }
    if (-not (Test-Path -LiteralPath $monitorPath -PathType Leaf)) {
        throw "Monitor script was not found: $monitorPath"
    }

    $shell = Get-PowerShellPath
    $arguments = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', $monitorPath
        '-RunDirectory', $RunDirectory
        '-Follow'
    )
    $argumentLine = ConvertTo-ProcessArgumentLine -Arguments $arguments

    # A direct powershell.exe child can inherit the harness' headless console.
    # Use Windows Terminal for the real monitor so the user receives a visible tab.
    $terminal = if ($usesDefaultMonitor -and $WindowStyle -eq 'Normal') {
        Get-Command wt.exe -ErrorAction SilentlyContinue
    }
    else {
        $null
    }
    if ($null -ne $terminal -and -not [string]::IsNullOrWhiteSpace($terminal.Source)) {
        $terminalArguments = @(
            'new-tab'
            '--title', 'DeepSeek Monitor'
            $shell
            '-NoExit'
            '-ExecutionPolicy', 'Bypass'
            '-File', $monitorPath
            '-RunDirectory', $RunDirectory
            '-Follow'
        )
        $terminalArgumentLine = ConvertTo-ProcessArgumentLine -Arguments $terminalArguments
        Start-Process -FilePath $terminal.Source -ArgumentList $terminalArgumentLine -WorkingDirectory $projectRoot | Out-Null
        return
    }

    Start-Process -FilePath $shell -ArgumentList $argumentLine -WorkingDirectory $projectRoot -WindowStyle $WindowStyle | Out-Null
}

function Get-TaskSection([string]$Task, [string]$Heading) {
    $pattern = "(?ms)^## $([regex]::Escape($Heading))\s*\r?\n(?<body>.*?)(?=^## |\z)"
    $match = [regex]::Match($Task, $pattern)
    if (-not $match.Success) { throw "Task is missing section: $Heading" }
    return $match.Groups['body'].Value
}

function Get-AllowedScopes([string]$Task) {
    $body = Get-TaskSection -Task $Task -Heading 'Allowed paths'
    $scopes = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($body, '(?m)^-\s+(.+?)\s*$')) {
        $path = $match.Groups[1].Value.Trim().Trim('`').Replace('\', '/')
        if ([string]::IsNullOrWhiteSpace($path) -or [System.IO.Path]::IsPathRooted($path) -or $path -match '(^|/)\.\.(/|$)') {
            throw "Invalid allowed scope: $path"
        }
        $scopes.Add($path.TrimEnd('/'))
    }
    if ($scopes.Count -eq 0) { throw 'Task must declare at least one allowed path.' }
    return $scopes
}

function Test-SensitivePath([string]$RelativePath) {
    $normalized = $RelativePath.Replace('\', '/')
    $leaf = [System.IO.Path]::GetFileName($normalized)
    if ($leaf -match '(?i)^\.env(\..*)?$') { return $true }
    if ($leaf -match '(?i)^(id_rsa|id_dsa|id_ecdsa|id_ed25519)(\..*)?$') { return $true }
    if ($leaf -match '(?i)^(credentials|secrets)(\.(json|ya?ml|txt|ini|cfg|conf|toml|env))?$') { return $true }
    if ($leaf -match '(?i)^(token)(\.(json|txt|ini|cfg|conf|toml))?$') { return $true }
    if ($leaf -match '(?i)\.(pem|key|pfx|p12|cer|crt)$') { return $true }
    if ($normalized -match '(?i)(^|/)(\.ssh|\.aws|\.azure|\.config/gcloud)(/|$)') { return $true }
    return $false
}

function Get-ProjectManifest {
    $manifest = @{}
    Get-ChildItem -LiteralPath $projectRoot -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $relative = $_.FullName.Substring($projectRoot.Length).TrimStart('\', '/').Replace('\', '/')
        if ($relative -like '.git/*') { return }
        if (Test-SensitivePath $relative) {
            # Track metadata only. Never open or hash credential-like files.
            $manifest[$relative] = 'sensitive|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks
            return
        }
        try {
            $manifest[$relative] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
        catch {
            $manifest[$relative] = '<unreadable>'
        }
    }
    return $manifest
}

function Test-TaskScope($Before, $After, $AllowedScopes) {
    $changed = [System.Collections.Generic.List[string]]::new()
    $outOfScope = [System.Collections.Generic.List[string]]::new()
    foreach ($path in @($Before.Keys + $After.Keys | Sort-Object -Unique)) {
        if ($Before[$path] -eq $After[$path]) { continue }
        $changed.Add($path)
        $allowed = $false
        foreach ($scope in $AllowedScopes) {
            if ($path -eq $scope -or $path.StartsWith($scope + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
                $allowed = $true
                break
            }
        }
        if (-not $allowed) { $outOfScope.Add($path) }
    }
    return [pscustomobject]@{ Changed = $changed; OutOfScope = $outOfScope; Valid = ($outOfScope.Count -eq 0) }
}

function Invoke-Launcher([string]$LauncherPath, [string]$StandardInput, [int]$TimeoutMilliseconds = 0, [string]$StdoutPath, [string]$StderrPath, [switch]$FollowOutput) {
    $shell = Get-PowerShellPath
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $shell
    $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$LauncherPath`""
    $startInfo.WorkingDirectory = $projectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.CreateNoWindow = $true

    $stdoutWriter = $null
    $stderrWriter = $null
    if (-not [string]::IsNullOrWhiteSpace($StdoutPath)) {
        $stdoutDirectory = Split-Path -Parent $StdoutPath
        if (-not (Test-Path -LiteralPath $stdoutDirectory -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $stdoutDirectory | Out-Null
        }
        $stdoutWriter = [System.IO.StreamWriter]::new($StdoutPath, $false, [System.Text.UTF8Encoding]::new($false))
        $stdoutWriter.AutoFlush = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($StderrPath)) {
        $stderrDirectory = Split-Path -Parent $StderrPath
        if (-not (Test-Path -LiteralPath $stderrDirectory -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $stderrDirectory | Out-Null
        }
        $stderrWriter = [System.IO.StreamWriter]::new($StderrPath, $false, [System.Text.UTF8Encoding]::new($false))
        $stderrWriter.AutoFlush = $true
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    $stdoutBuilder = [System.Text.StringBuilder]::new()
    $stderrBuilder = [System.Text.StringBuilder]::new()
    $timedOut = $false
    $exitCode = -1
    try {
        if (-not $process.Start()) { throw 'Failed to start harness child process.' }
        $started = $true
        $stdoutTask = $process.StandardOutput.ReadLineAsync()
        $stderrTask = $process.StandardError.ReadLineAsync()
        $stdoutDone = $false
        $stderrDone = $false
        if ($null -ne $StandardInput) { $process.StandardInput.Write($StandardInput) }
        $process.StandardInput.Close()

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not ($stdoutDone -and $stderrDone -and $process.HasExited)) {
            if (-not $stdoutDone -and $null -ne $stdoutTask -and $stdoutTask.IsCompleted) {
                try { $line = $stdoutTask.GetAwaiter().GetResult() }
                catch { $line = $null }
                if ($null -eq $line) {
                    $stdoutDone = $true
                    $stdoutTask = $null
                }
                else {
                    if ($null -eq $stdoutWriter) { [void]$stdoutBuilder.AppendLine($line) }
                    if ($null -ne $stdoutWriter) { $stdoutWriter.WriteLine($line) }
                    if ($FollowOutput) { Write-Host $line }
                    $stdoutTask = $process.StandardOutput.ReadLineAsync()
                }
            }

            if (-not $stderrDone -and $null -ne $stderrTask -and $stderrTask.IsCompleted) {
                try { $line = $stderrTask.GetAwaiter().GetResult() }
                catch { $line = $null }
                if ($null -eq $line) {
                    $stderrDone = $true
                    $stderrTask = $null
                }
                else {
                    if ($null -eq $stderrWriter) { [void]$stderrBuilder.AppendLine($line) }
                    if ($null -ne $stderrWriter) { $stderrWriter.WriteLine($line) }
                    if ($FollowOutput) { Write-Warning $line }
                    $stderrTask = $process.StandardError.ReadLineAsync()
                }
            }

            if (-not $process.HasExited -and $TimeoutMilliseconds -gt 0 -and $stopwatch.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
                $timedOut = $true
                try { $process.Kill() } catch { }
                # Unblock any pending line reads once the timed-out child is gone.
                try { $process.StandardOutput.Close() } catch { }
                try { $process.StandardError.Close() } catch { }
            }

            if (-not ($stdoutDone -and $stderrDone -and $process.HasExited)) {
                Start-Sleep -Milliseconds 25
            }
        }

        $process.WaitForExit()
        $exitCode = [int]$process.ExitCode
    }
    finally {
        if ($null -ne $stdoutWriter) { $stdoutWriter.Dispose() }
        if ($null -ne $stderrWriter) { $stderrWriter.Dispose() }
        if ($started -and -not $process.HasExited) {
            try { $process.Kill() } catch { }
        }
        $process.Dispose()
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Stdout = $stdoutBuilder.ToString()
        Stderr = $stderrBuilder.ToString()
        TimedOut = $timedOut
    }
}

function Invoke-DshProcess([string]$DshExecutable, [string]$TaskText, [string]$RunDirectory, [string]$PermissionMode, [string]$ApprovalPolicy, [bool]$FollowOutput) {
    $launcherPath = Join-Path $RunDirectory 'invoke-dsh.ps1'
    $eventsPath = Join-Path $RunDirectory 'events.jsonl'
    $stderrPath = Join-Path $RunDirectory 'stderr.log'
    foreach ($path in @($eventsPath, $stderrPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            New-Item -ItemType File -Force -Path $path | Out-Null
        }
    }

    $escapedPath = $DshExecutable.Replace("'", "''")
    $launcher = "& '$escapedPath' headless --json --permission-mode '$PermissionMode' --approval-policy '$ApprovalPolicy' -`r`nexit `$LASTEXITCODE"
    Set-Content -LiteralPath $launcherPath -Value $launcher -Encoding utf8

    $outcome = Invoke-Launcher -LauncherPath $launcherPath -StandardInput $TaskText -StdoutPath $eventsPath -StderrPath $stderrPath -FollowOutput:$FollowOutput
    return [int]$outcome.ExitCode
}

function Write-Report {
    param(
        [string]$Result,
        [string]$Message,
        [string]$RunDirectory,
        [int]$ModelExitCode,
        [int]$TestExitCode,
        $ScopeResult,
        [string]$TaskId = '',
        [string]$DeliveryState = 'not_requested',
        [string]$ErrorMessage = ''
    )

    $changed = if ($null -eq $ScopeResult) { 'not run' } elseif ($ScopeResult.Changed.Count -eq 0) { 'none' } else { $ScopeResult.Changed -join ', ' }
    $outOfScope = if ($null -eq $ScopeResult) { 'not run' } elseif ($ScopeResult.OutOfScope.Count -eq 0) { 'none' } else { $ScopeResult.OutOfScope -join ', ' }
    try {
        $gitStatus = (& git -C $projectRoot status --short -- . 2>&1 | Out-String).Trim()
    }
    catch {
        $gitStatus = "git status unavailable: $($_.Exception.Message)"
    }
    $gitStatus = (@($gitStatus -split '\r?\n') | Where-Object {
        $_ -notmatch '(?i)(^|[\s/\\])\.env([.\s/\\]|$)' -and
        $_ -notmatch '(?i)\.(pem|key|pfx|p12)\b'
    }) -join [Environment]::NewLine

    $reportLines = @(
        '# DeepSeek Harness report'
        ''
        "- Result: $Result"
        "- Message: $Message"
        "- Task ID: $TaskId"
        "- Task: $taskPath"
        "- Run directory: $RunDirectory"
        "- Model exit code: $ModelExitCode"
        "- Test exit code: $TestExitCode"
        "- Initial delivery state: $DeliveryState"
    )
    if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
        $reportLines += "- Harness error: $ErrorMessage"
    }
    $reportLines += @(
        ''
        '## Scope check'
        ''
        "- Changed files: $changed"
        "- Out-of-scope files: $outOfScope"
        ''
        '## Git status after run'
        ''
        '```'
        $gitStatus
        '```'
    )
    Set-Content -LiteralPath $reportPath -Value ($reportLines -join [Environment]::NewLine) -Encoding utf8
}

function Add-ReportDelivery {
    param(
        [string]$State,
        [string]$Thread,
        [bool]$Attempted,
        [int]$QueueExitCode,
        [string]$QueueLog,
        [string]$ReviewMessagePath,
        [string]$QueueError
    )
    $lines = @(
        ''
        '## Handoff delivery'
        ''
        "- State: $State"
        "- Codex thread: $Thread"
        "- Queue attempted: $Attempted"
        "- Queue exit code: $QueueExitCode"
        "- Queue log: $QueueLog"
        "- Review message: $ReviewMessagePath"
    )
    if (-not [string]::IsNullOrWhiteSpace($QueueError)) { $lines += "- Queue error: $QueueError" }
    Add-Content -LiteralPath $reportPath -Value ($lines -join [Environment]::NewLine) -Encoding utf8
}

function Get-NextAction([string]$TerminalStatus, [string]$DeliveryState) {
    if ($TerminalStatus -ne 'passed') {
        if ($DeliveryState -eq 'failed') {
            return 'Stop. Fix the failed run and the failed review delivery; inspect RESULT.json and codex-queue.log before any new delegation. Do not rerun automatically.'
        }
        return 'Stop. Review the failed run artifacts and scope/test evidence; fix the cause before any new delegation. Do not rerun automatically.'
    }
    switch ($DeliveryState) {
        'queued' { return 'Await the single queued Codex review; do not start another modifying delegation until it is accepted.' }
        'failed' { return 'The run passed but the Codex review was not queued. Inspect codex-queue.log and hand RESULT.json to Codex manually; do not rerun DeepSeek.' }
        'pending' { return 'Handoff delivery is pending; inspect codex-queue.log and RESULT.json. Do not rerun DeepSeek automatically.' }
        default { return 'Review the report and changed paths; accept the result or create the next bounded task.' }
    }
}

function New-ReviewInstruction([string]$ResultPath) {
    $instruction = @"
Review the DeepSeek handoff recorded at $ResultPath.
Read only RESULT.json and the artifacts it references; do not read raw event or stderr logs.
Stop and report without further changes if the result is failed, the scope check reports out-of-scope changes, tests failed, interactive host-application access is required, or the milestone is complete.
Otherwise review the changed paths against the task snapshot, run the declared test command at most once, and either accept the result or list concrete defects.
This is one finite review request: do not queue another review, retry automatically, start a background service or poller, or modify files outside the task scope.
"@
    $instruction = $instruction.Trim()
    if ($instruction.Length -gt $reviewInstructionLimit) {
        throw "Review instruction exceeds the $reviewInstructionLimit-character bound."
    }
    return $instruction
}

function Invoke-CodexQueue([string]$Thread, [string]$ResultPath, [string]$RunDirectory) {
    $messagePath = Join-Path $RunDirectory 'codex-message.txt'
    $queueLogPath = Join-Path $RunDirectory 'codex-queue.log'
    $outcome = [ordered]@{
        state = 'failed'
        attempted = $false
        exit_code = -1
        log = $queueLogPath
        message_path = $messagePath
        error = ''
    }

    try {
        $instruction = New-ReviewInstruction -ResultPath $ResultPath
        Set-Content -LiteralPath $messagePath -Value $instruction -Encoding utf8
    }
    catch {
        $outcome.error = "Could not prepare the review message: $($_.Exception.Message)"
        Set-Content -LiteralPath $queueLogPath -Value $outcome.error -Encoding utf8
        return [pscustomobject]$outcome
    }

    try {
        $codex = if (-not [string]::IsNullOrWhiteSpace($CodexPath)) {
            Get-Command $CodexPath -ErrorAction Stop
        }
        else {
            Get-Command codex -ErrorAction Stop
        }
        $codexExecutable = $codex.Source
    }
    catch {
        $outcome.error = 'Codex executable was not found; the review was not queued.'
        Set-Content -LiteralPath $queueLogPath -Value $outcome.error -Encoding utf8
        return [pscustomobject]$outcome
    }

    $launcherPath = Join-Path $RunDirectory 'invoke-codex-queue.ps1'
    $escapedCodex = $codexExecutable.Replace("'", "''")
    $escapedThread = $Thread.Replace("'", "''")
    $escapedMessagePath = $messagePath.Replace("'", "''")
    $launcher = @"
`$review = Get-Content -LiteralPath '$escapedMessagePath' -Raw
& '$escapedCodex' queue --thread '$escapedThread' --message `$review
exit `$LASTEXITCODE
"@

    try {
        Set-Content -LiteralPath $launcherPath -Value $launcher -Encoding utf8
        $outcome.attempted = $true
        $process = Invoke-Launcher -LauncherPath $launcherPath -StandardInput $null -TimeoutMilliseconds 120000
        $logText = @(
            "codex exit code: $($process.ExitCode)"
            "timed out: $($process.TimedOut)"
            '--- stdout ---'
            $process.Stdout
            '--- stderr ---'
            $process.Stderr
        ) -join [Environment]::NewLine
        Set-Content -LiteralPath $queueLogPath -Value $logText -Encoding utf8

        if ($process.TimedOut) {
            $outcome.exit_code = -2
            $outcome.error = 'The Codex queue call timed out after 120 seconds.'
        }
        else {
            $outcome.exit_code = [int]$process.ExitCode
            if ($process.ExitCode -ne 0) {
                $outcome.error = "The Codex queue call failed with exit code $($process.ExitCode)."
            }
            else {
                $outcome.state = 'queued'
            }
        }
    }
    catch {
        $outcome.exit_code = -1
        $outcome.error = "The Codex queue call could not be started: $($_.Exception.Message)"
        Set-Content -LiteralPath $queueLogPath -Value $outcome.error -Encoding utf8
    }
    return [pscustomobject]$outcome
}

function Write-RunResult {
    param(
        [string]$TaskId,
        [string]$TerminalStatus,
        [string]$RunId,
        [string]$CreatedAt,
        [int]$ModelExitCode,
        [object]$ChangedPaths,
        [object]$AllowedScopes,
        [bool]$ScopeValid,
        [object]$OutOfScope,
        [int]$TestExitCode,
        [string]$ReportPath,
        [string]$ResultPath,
        [string]$RunDirectory,
        [string]$DeliveryState,
        [string]$CodexThread,
        [bool]$QueueAttempted,
        [int]$QueueExitCode,
        [string]$QueueLog,
        [string]$MessagePath,
        [string]$QueueError,
        [string]$MilestonePath,
        [string]$NextAction,
        [string]$ErrorMessage
    )

    $changedArray = @()
    if ($null -ne $ChangedPaths) { $changedArray = @($ChangedPaths) }
    $allowedArray = @()
    if ($null -ne $AllowedScopes) { $allowedArray = @($AllowedScopes) }
    $outOfScopeArray = @()
    if ($null -ne $OutOfScope) { $outOfScopeArray = @($OutOfScope) }

    $result = [ordered]@{
        task_id = $TaskId
        terminal_status = $TerminalStatus
        run_id = $RunId
        created_at = $CreatedAt
        finished_at = (Get-Date -Format o)
        model_exit_code = $ModelExitCode
        changed_paths = $changedArray
        scope_result = [ordered]@{
            valid = $ScopeValid
            allowed_paths = $allowedArray
            changed_paths = $changedArray
            out_of_scope = $outOfScopeArray
        }
        test_exit_code = $TestExitCode
        report_path = $ReportPath
        result_path = $ResultPath
        run_directory = $RunDirectory
        delivery_state = $DeliveryState
        delivery = [ordered]@{
            state = $DeliveryState
            codex_thread = $CodexThread
            attempted = $QueueAttempted
            queue_exit_code = $QueueExitCode
            queue_log = $QueueLog
            message_path = $MessagePath
            error = $QueueError
        }
        milestone_path = $MilestonePath
        next_action = $NextAction
        error = $ErrorMessage
    }
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $RunDirectory 'RESULT.json') -Encoding utf8
}

if (-not (Test-Path -LiteralPath $taskPath)) { throw "Missing task file: $taskPath" }
$task = Get-Content -LiteralPath $taskPath -Raw
if ($task -notmatch '(?m)^Task-Status:\s*ready\s*$') { throw 'Task-Status must be ready.' }
$taskId = ([regex]::Match($task, '(?m)^Task-ID:\s*(\S+)\s*$')).Groups[1].Value.Trim()
if ([string]::IsNullOrWhiteSpace($taskId)) { throw 'Task-ID is required.' }
$testCommand = ([regex]::Match($task, '(?m)^Test-Command:\s*(.*)$')).Groups[1].Value.Trim()
if ([string]::IsNullOrWhiteSpace($testCommand) -and -not $DryRun) { throw 'A real delegation requires Test-Command.' }
$allowedScopes = @(Get-AllowedScopes $task)

if (-not (Test-Path -LiteralPath $milestonePath -PathType Leaf)) { throw "Missing milestone file: $milestonePath" }
$milestone = Get-Content -LiteralPath $milestonePath -Raw
if ($milestone -notmatch '(?im)^#+\s*(Predeclared boundary|Boundary)\b') { throw 'Milestone must declare a predeclared boundary.' }
if ($milestone -notmatch '(?im)^#+\s*Stop rules\b') { throw 'Milestone must declare stop rules.' }

$dsh = if (-not [string]::IsNullOrWhiteSpace($DshPath)) {
    Get-Command $DshPath -ErrorAction Stop
}
else {
    Get-Command dsh -ErrorAction Stop
}
$dshExecutable = $dsh.Source
& $dshExecutable headless --help | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'dsh headless --help failed.' }

if ($DryRun) {
    Write-Report -Result 'dry-run' -Message 'CLI, task format, milestone, and executable checks verified; no model was invoked.' -RunDirectory 'n/a' -ModelExitCode -1 -TestExitCode -1 -ScopeResult $null -TaskId $taskId -DeliveryState 'not_requested'
    Write-Output "Dry run complete: $reportPath"
    return
}

if (-not [string]::IsNullOrWhiteSpace($CodexThread)) {
    if ($CodexThread.Length -gt 200) { throw 'CodexThread is longer than the 200-character limit.' }
    if ($CodexThread -match '[\r\n\x00]') { throw 'CodexThread must not contain control characters.' }
}

if (Test-Path -LiteralPath $lockDirectory) {
    throw "Existing run lock: $lockDirectory. Verify no owner or DeepSeek process is active, then run Repair-DeepSeekLock.ps1 -ProjectRoot '$projectRoot' -ControlRoot '$controlRoot'."
}

$lockToken = [guid]::NewGuid().ToString()
$lockCreated = $false
$ownerWritten = $false
$runId = Get-Date -Format 'yyyyMMdd-HHmmss-ffff'
$runDirectory = Join-Path $controlRoot (Join-Path 'runs' $runId)
$resultPath = Join-Path $runDirectory 'RESULT.json'
$createdAt = Get-Date -Format o

$modelExitCode = -1
$testExitCode = -1
$scopeResult = $null
$changedPaths = @()
$outOfScope = @()
$scopeValid = $false
$terminalStatus = 'failed'
$reportWritten = $false
$deliveryState = if ([string]::IsNullOrWhiteSpace($CodexThread)) { 'not_requested' } else { 'pending' }
$queueAttempted = $false
$queueExitCode = -1
$queueLog = ''
$messagePath = ''
$queueError = ''
$harnessError = ''

try {
try {
    if (Test-Path -LiteralPath $lockDirectory) {
        throw "Existing run lock: $lockDirectory"
    }
    New-Item -ItemType Directory -Path $lockDirectory -ErrorAction Stop | Out-Null
    $lockCreated = $true
    try { $processStart = (Get-Process -Id $PID).StartTime.ToString('o') }
    catch { $processStart = $null }
    $owner = [ordered]@{
        pid = $PID
        process_started_at = $processStart
        started_at = $createdAt
        token = $lockToken
        task_id = $taskId
    }
    $owner | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $lockOwnerPath -Encoding utf8
    $ownerWritten = $true

    New-Item -ItemType Directory -Force -Path $runDirectory -ErrorAction Stop | Out-Null
    Copy-Item -LiteralPath $taskPath -Destination (Join-Path $runDirectory 'TASK.md')

    # Create the artifacts first so a monitor can follow this run from its start.
    $eventsPath = Join-Path $runDirectory 'events.jsonl'
    $stderrPath = Join-Path $runDirectory 'stderr.log'
    Set-Content -LiteralPath $eventsPath -Value '' -Encoding utf8
    Set-Content -LiteralPath $stderrPath -Value '' -Encoding utf8
    if ($OpenMonitor) {
        Start-RunMonitor -RunDirectory $runDirectory -MonitorScript $MonitorScriptPath -WindowStyle $MonitorWindowStyle
    }

    $before = Get-ProjectManifest
    $modelExitCode = Invoke-DshProcess -DshExecutable $dshExecutable -TaskText $task -RunDirectory $runDirectory -PermissionMode $PermissionMode -ApprovalPolicy $ApprovalPolicy -FollowOutput $Follow.IsPresent

    $after = Get-ProjectManifest
    $scopeResult = Test-TaskScope $before $after $allowedScopes
    $changedPaths = @($scopeResult.Changed)
    $outOfScope = @($scopeResult.OutOfScope)
    $scopeValid = [bool]$scopeResult.Valid

    if ($modelExitCode -eq 0 -and $scopeValid -and $RunTests) {
        Push-Location $projectRoot
        try {
            $powerShellExecutable = Get-PowerShellPath
            & $powerShellExecutable -NoProfile -Command $testCommand 1> (Join-Path $runDirectory 'test.log') 2>&1
            $testExitCode = $LASTEXITCODE
        }
        finally { Pop-Location }
    }

    $passed = $modelExitCode -eq 0 -and $scopeValid -and ((-not $RunTests) -or $testExitCode -eq 0)
    $terminalStatus = if ($passed) { 'passed' } else { 'failed' }
    $message = if ($passed) { 'Model run, scope check, and requested test passed.' } else { 'Review run artifacts, scope check, and test output.' }
    Write-Report -Result $terminalStatus -Message $message -RunDirectory $runDirectory -ModelExitCode $modelExitCode -TestExitCode $testExitCode -ScopeResult $scopeResult -TaskId $taskId -DeliveryState $deliveryState
    $reportWritten = $true
}
catch {
    $harnessError = $_.Exception.Message
    $terminalStatus = 'failed'
}

if (-not (Test-Path -LiteralPath $runDirectory -PathType Container)) {
    throw "Run directory was not created: $runDirectory. $harnessError"
}

if (-not $reportWritten) {
    try {
        Write-Report -Result 'failed' -Message 'The harness could not complete the delegated run.' -RunDirectory $runDirectory -ModelExitCode $modelExitCode -TestExitCode $testExitCode -ScopeResult $scopeResult -TaskId $taskId -DeliveryState $deliveryState -ErrorMessage $harnessError
        $reportWritten = Test-Path -LiteralPath $reportPath
    }
    catch {
        if ([string]::IsNullOrWhiteSpace($harnessError)) { $harnessError = $_.Exception.Message }
    }
}

$nextAction = Get-NextAction -TerminalStatus $terminalStatus -DeliveryState $deliveryState
Write-RunResult -TaskId $taskId -TerminalStatus $terminalStatus -RunId $runId -CreatedAt $createdAt -ModelExitCode $modelExitCode -ChangedPaths $changedPaths -AllowedScopes $allowedScopes -ScopeValid $scopeValid -OutOfScope $outOfScope -TestExitCode $testExitCode -ReportPath $reportPath -ResultPath $resultPath -RunDirectory $runDirectory -DeliveryState $deliveryState -CodexThread $CodexThread -QueueAttempted $queueAttempted -QueueExitCode $queueExitCode -QueueLog $queueLog -MessagePath $messagePath -QueueError $queueError -MilestonePath $milestonePath -NextAction $nextAction -ErrorMessage $harnessError

if (-not [string]::IsNullOrWhiteSpace($CodexThread) -and $reportWritten -and (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
    $queueOutcome = Invoke-CodexQueue -Thread $CodexThread -ResultPath $resultPath -RunDirectory $runDirectory
    $queueAttempted = [bool]$queueOutcome.attempted
    $queueExitCode = [int]$queueOutcome.exit_code
    $queueLog = [string]$queueOutcome.log
    $messagePath = [string]$queueOutcome.message_path
    $queueError = [string]$queueOutcome.error
    $deliveryState = if ($queueOutcome.state -eq 'queued') { 'queued' } else { 'failed' }
    $nextAction = Get-NextAction -TerminalStatus $terminalStatus -DeliveryState $deliveryState
    Write-RunResult -TaskId $taskId -TerminalStatus $terminalStatus -RunId $runId -CreatedAt $createdAt -ModelExitCode $modelExitCode -ChangedPaths $changedPaths -AllowedScopes $allowedScopes -ScopeValid $scopeValid -OutOfScope $outOfScope -TestExitCode $testExitCode -ReportPath $reportPath -ResultPath $resultPath -RunDirectory $runDirectory -DeliveryState $deliveryState -CodexThread $CodexThread -QueueAttempted $queueAttempted -QueueExitCode $queueExitCode -QueueLog $queueLog -MessagePath $messagePath -QueueError $queueError -MilestonePath $milestonePath -NextAction $nextAction -ErrorMessage $harnessError
    try {
        Add-ReportDelivery -State $deliveryState -Thread $CodexThread -Attempted $queueAttempted -QueueExitCode $queueExitCode -QueueLog $queueLog -ReviewMessagePath $messagePath -QueueError $queueError
    }
    catch {
        if ([string]::IsNullOrWhiteSpace($harnessError)) { $harnessError = "Could not append delivery state to the report: $($_.Exception.Message)" }
    }
}

}
finally {
    if ($lockCreated) {
        $removeLock = $false
        if ($ownerWritten -and (Test-Path -LiteralPath $lockOwnerPath -PathType Leaf)) {
            try {
                $currentOwner = Get-Content -LiteralPath $lockOwnerPath -Raw | ConvertFrom-Json
                if ($currentOwner.token -eq $lockToken) { $removeLock = $true }
            }
            catch { $removeLock = $false }
        }
        elseif (-not $ownerWritten) {
            $removeLock = $true
        }
        if ($removeLock -and (Test-Path -LiteralPath $lockDirectory)) {
            Remove-Item -LiteralPath $lockDirectory -Recurse -Force
        }
    }
}

if ($terminalStatus -ne 'passed') {
    throw "Delegation failed; review $reportPath and $resultPath"
}
if (-not [string]::IsNullOrWhiteSpace($CodexThread) -and $deliveryState -ne 'queued') {
    throw "Codex review delivery state is '$deliveryState'; RESULT.json retained at $resultPath. Do not rerun DeepSeek."
}
Write-Output "Delegation passed: $resultPath"
