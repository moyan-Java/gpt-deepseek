[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunDirectory,
    [ValidateRange(1, 500)]
    [int]$Tail = 20,
    [switch]$Follow,
    [ValidateRange(50, 60000)]
    [int]$PollMilliseconds = 250,
    [ValidateRange(0, 86400)]
    [int]$FollowTimeoutSeconds = 0
)

$ErrorActionPreference = 'Stop'
$runDirectory = [System.IO.Path]::GetFullPath($RunDirectory)
$eventsPath = Join-Path $runDirectory 'events.jsonl'
$stderrPath = Join-Path $runDirectory 'stderr.log'
$resultPath = Join-Path $runDirectory 'RESULT.json'
$taskPath = Join-Path $runDirectory 'TASK.md'
$toolByCallId = @{}
$script:planShown = $false

if (-not (Test-Path -LiteralPath $runDirectory -PathType Container)) {
    throw "运行目录不存在：$runDirectory"
}

function Read-FileText([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
            try { return $reader.ReadToEnd() }
            finally { $reader.Dispose() }
        }
        finally { $stream.Dispose() }
    }
    catch { return $null }
}

function Read-FileLines([string]$Path) {
    $text = Read-FileText $Path
    if ([string]::IsNullOrEmpty($text)) { return @() }
    $lines = @($text -split '\r?\n')
    if (-not $text.EndsWith("`n")) {
        # 正在写入的最后一行不参与展示。
        if ($lines.Count -le 1) { return @() }
        $lines = @($lines[0..($lines.Count - 2)])
    }
    return @($lines | Where-Object { -not [string]::IsNullOrEmpty($_) })
}

function Test-SensitivePath([string]$Path) {
    $leaf = [System.IO.Path]::GetFileName($Path)
    return $leaf -match '(?i)^\.env(\..*)?$|^(credentials|secrets|token)(\..*)?$|\.(pem|key|pfx|p12)$'
}

function Get-SafePath([object]$Value) {
    $path = [string]$Value
    if ([string]::IsNullOrWhiteSpace($path)) { return '' }
    if (Test-SensitivePath $path) { return '敏感路径已隐藏' }
    return $path
}

function Get-ToolLabel([string]$Tool) {
    switch ($Tool) {
        'read' { return '读取文件' }
        'edit' { return '修改文件' }
        'glob' { return '搜索文件' }
        'pwsh' { return '执行命令' }
        'skill' { return '加载技能' }
        'subagent' { return '启动子代理' }
        'working_directory' { return '切换工作目录' }
        default { return '调用工具' }
    }
}

function Get-TaskSection([string]$Task, [string[]]$Headings) {
    foreach ($heading in $Headings) {
        $pattern = "(?ms)^## $([regex]::Escape($heading))\s*\r?\n(?<body>.*?)(?=^## |\z)"
        $match = [regex]::Match($Task, $pattern)
        if ($match.Success) { return $match.Groups['body'].Value.Trim() }
    }
    return ''
}

function Show-GptInstruction {
    $task = Read-FileText $taskPath
    if ([string]::IsNullOrWhiteSpace($task)) {
        Write-Output '【GPT 指令】任务快照不可读取。'
        return
    }

    $goal = Get-TaskSection $task @('目标', 'Goal')
    $scope = Get-TaskSection $task @('允许路径', 'Allowed paths')
    $criteria = Get-TaskSection $task @('验收条件', 'Acceptance criteria')
    Write-Output '【GPT 指令】'
    if ($goal) { Write-Output "目标：$goal" }
    if ($scope) { Write-Output "允许修改：$scope" }
    if ($criteria) { Write-Output "验收条件：$criteria" }
}

function ConvertTo-ProgressText([string]$Line) {
    try { $event = $Line | ConvertFrom-Json -ErrorAction Stop }
    catch { return '收到一条运行事件。' }

    switch ([string]$event.type) {
        'session' { return '【DeepSeek 执行】已建立会话。' }
        'thinking' { return $null }
        'text' {
            if ($script:planShown) { return '【DeepSeek 执行】提交了补充说明。' }
            $script:planShown = $true
            $text = ([string]$event.text).Trim()
            if ($text -match '[一-龥]') {
                if ($text.Length -gt 600) { $text = $text.Substring(0, 600) + '……' }
                return "【DeepSeek 方案】$text"
            }
            return '【DeepSeek 方案】未按中文格式输出，原文已隐藏。'
        }
        'status' {
            switch ([string]$event.phase) {
                'turn_start' { return '【DeepSeek 执行】开始处理当前任务。' }
                'turn_end' { return '【DeepSeek 执行】当前任务处理结束。' }
                'step_start' { return '【DeepSeek 执行】开始执行下一步。' }
                'step_end' { return '【DeepSeek 执行】已完成一个执行步骤。' }
                default { return '【DeepSeek 执行】运行状态已更新。' }
            }
        }
        'tool_call' {
            $tool = [string]$event.input.tool
            if (-not [string]::IsNullOrWhiteSpace([string]$event.callId)) {
                $toolByCallId[[string]$event.callId] = $tool
            }
            $label = Get-ToolLabel $tool
            $path = Get-SafePath $event.input.file_path
            if ($path) { return "【DeepSeek 执行】正在$label：$path" }
            return "【DeepSeek 执行】正在$label。"
        }
        'tool_result' {
            $tool = $toolByCallId[[string]$event.callId]
            $label = Get-ToolLabel $tool
            if ([string]$event.status -eq 'completed') { return "【DeepSeek 执行】$label已完成。" }
            return "【DeepSeek 执行】$label未完成，已记录阻塞信息。"
        }
        default { return '【DeepSeek 执行】收到一条运行事件。' }
    }
}

function Show-ProgressLines([object[]]$Lines) {
    foreach ($line in $Lines) {
        $text = ConvertTo-ProgressText ([string]$line)
        if (-not [string]::IsNullOrWhiteSpace($text)) { Write-Output $text }
    }
}

function Show-TerminalResult {
    $raw = Read-FileText $resultPath
    if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
    try { $result = $raw | ConvertFrom-Json -ErrorAction Stop }
    catch { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$result.terminal_status)) { return $false }

    Write-Host ''
    Write-Host '【系统验收】'
    $status = if ([string]$result.terminal_status -eq 'passed') { '成功' } else { '失败' }
    Write-Host "最终状态：$status"
    Write-Host "任务编号：$($result.task_id)"
    Write-Host "变更文件数：$(@($result.changed_paths).Count)"
    Write-Host "范围检查：$(if ($result.scope_result.valid) { '通过' } else { '不通过' })"
    Write-Host "测试退出码：$($result.test_exit_code)"
    if ($status -eq '失败') { Write-Host '请回到 GPT 对话查看失败原因和下一步决策。' }
    return $true
}

if (-not $Follow) {
    Write-Output "任务快照：$runDirectory"
    Show-GptInstruction
    Show-ProgressLines @(Read-FileLines $eventsPath | Select-Object -Last $Tail)
    $stderrCount = @(Read-FileLines $stderrPath).Count
    if ($stderrCount -gt 0) { Write-Output "已记录 $stderrCount 条诊断信息，原文不在窗口显示。" }
    [void](Show-TerminalResult)
    return
}

Write-Output "正在监视 DeepSeek 任务：$runDirectory"
Write-Output '窗口只显示中文动作摘要；模型内部推理、原始命令和诊断原文不会显示。'
Show-GptInstruction

$events = @(Read-FileLines $eventsPath)
Show-ProgressLines $events
$eventCount = $events.Count
$stderrCount = @(Read-FileLines $stderrPath).Count
if ($stderrCount -gt 0) {
    Write-Output "已记录 $stderrCount 条诊断信息，原文不在窗口显示。"
}
$followStarted = Get-Date

while ($true) {
    $events = @(Read-FileLines $eventsPath)
    if ($events.Count -gt $eventCount) {
        Show-ProgressLines @($events[$eventCount..($events.Count - 1)])
        $eventCount = $events.Count
    }
    elseif ($events.Count -lt $eventCount) { $eventCount = $events.Count }

    $newStderrCount = @(Read-FileLines $stderrPath).Count
    if ($newStderrCount -gt $stderrCount) {
        Write-Output "新增 $($newStderrCount - $stderrCount) 条诊断信息，原文已隐藏。"
        $stderrCount = $newStderrCount
    }

    if (Show-TerminalResult) { return }
    if ($FollowTimeoutSeconds -gt 0 -and ((Get-Date) - $followStarted).TotalSeconds -ge $FollowTimeoutSeconds) {
        throw "监视超时：$FollowTimeoutSeconds 秒内未收到最终结果。"
    }
    Start-Sleep -Milliseconds $PollMilliseconds
}
