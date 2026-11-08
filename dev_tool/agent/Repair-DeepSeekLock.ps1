[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot,

    [Parameter(Mandatory)]
    [string]$ControlRoot
)

$ErrorActionPreference = 'Stop'

$projectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$controlRoot = [System.IO.Path]::GetFullPath($ControlRoot)
if (-not (Test-Path -LiteralPath $projectRoot -PathType Container)) {
    throw "ProjectRoot does not exist: $projectRoot"
}
$lockDirectory = Join-Path $controlRoot 'run.lock'
$ownerPath = Join-Path $lockDirectory 'owner.json'

function ConvertTo-OwnerDate([object]$Value) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    if ($Value -is [datetime]) { return $Value }
    if ($Value -is [datetimeoffset]) { return $Value.LocalDateTime }
    return [datetime]::Parse(
        [string]$Value,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind)
}

function Get-OwnerProcessState([int]$OwnerPid, [object]$RecordedStart) {
    $process = Get-Process -Id $OwnerPid -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return [pscustomobject]@{
            Present = $false
            StartMatches = $false
            ActualStart = $null
        }
    }

    if ($null -eq $RecordedStart) {
        # Older locks have no process start time. A live PID is treated as the
        # owner because this command must fail closed when identity is unclear.
        return [pscustomobject]@{
            Present = $true
            StartMatches = $true
            ActualStart = $null
        }
    }

    try {
        $actualStart = $process.StartTime
    }
    catch {
        throw "Cannot read the start time of PID $OwnerPid ($($process.ProcessName)); refusing stale-lock recovery."
    }

    $deltaSeconds = [math]::Abs(($actualStart - $RecordedStart).TotalSeconds)
    return [pscustomobject]@{
        Present = $true
        StartMatches = ($deltaSeconds -le 2)
        ActualStart = $actualStart
    }
}

function Get-MatchingDshProcesses {
    try {
        $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    }
    catch {
        throw "Cannot enumerate processes to verify DeepSeek activity; refusing stale-lock recovery. $($_.Exception.Message)"
    }

    # A recovery launched by a harness/test is itself a child of that harness.
    # Do not mistake the invoking process tree for an unrelated active run.
    $excluded = [System.Collections.Generic.HashSet[int]]::new()
    [void]$excluded.Add($PID)
    $byId = @{}
    foreach ($process in $processes) {
        if ($null -ne $process) { $byId[[int]$process.ProcessId] = $process }
    }
    $currentPid = $PID
    for ($depth = 0; $depth -lt 64; $depth++) {
        $current = $byId[$currentPid]
        if ($null -eq $current) { break }
        $parentPid = [int]$current.ParentProcessId
        if ($parentPid -le 0 -or $excluded.Contains($parentPid)) { break }
        [void]$excluded.Add($parentPid)
        $currentPid = $parentPid
    }

    $matchingProcesses = [System.Collections.Generic.List[object]]::new()
    foreach ($process in $processes) {
        if ($null -eq $process -or $excluded.Contains([int]$process.ProcessId)) { continue }

        $name = [string]$process.Name
        $commandLine = [string]$process.CommandLine
        $nameMatches = $name -match '(?i)^dsh(?:[.-][\w-]+)?(?:\.exe)?$'
        $commandMatches = $commandLine -match '(?i)(^|[\\/\s"''=])(?:dsh|deepseek)(?:[._-][\w.-]+)*(?:\.(?:exe|cmd|bat|ps1|js|mjs|cjs))?(?=["''\s]|$)' -and
            $commandLine -match '(?i)\bheadless\b'

        if ($nameMatches -or $commandMatches) {
            $matchingProcesses.Add([pscustomobject]@{
                pid = [int]$process.ProcessId
                name = $name
            })
        }
    }
    return $matchingProcesses
}

if (-not (Test-Path -LiteralPath $lockDirectory -PathType Container)) {
    Write-Output "No run lock at $lockDirectory; nothing to recover."
    return
}

$lockItem = Get-Item -LiteralPath $lockDirectory -Force
if ($lockItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    throw "Refusing recovery: the lock directory is a reparse point. Evidence was left in place."
}

if (-not (Test-Path -LiteralPath $ownerPath -PathType Leaf)) {
    throw "Refusing recovery: lock has no owner.json at $ownerPath. Evidence was left in place."
}

$ownerItem = Get-Item -LiteralPath $ownerPath -Force
if ($ownerItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    throw "Refusing recovery: owner.json is a reparse point. Evidence was left in place."
}

try {
    $owner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json
}
catch {
    throw "Refusing recovery: owner.json cannot be parsed. Evidence was left in place. $($_.Exception.Message)"
}

$ownerPid = 0
if (-not [int]::TryParse([string]$owner.pid, [ref]$ownerPid) -or $ownerPid -le 0) {
    throw "Refusing recovery: owner.json has no valid pid. Evidence was left in place."
}

try {
    $recordedStart = ConvertTo-OwnerDate $owner.process_started_at
}
catch {
    throw "Refusing recovery: owner.json process_started_at is invalid. Evidence was left in place. $($_.Exception.Message)"
}

$ownerState = Get-OwnerProcessState -OwnerPid $ownerPid -RecordedStart $recordedStart
if ($ownerState.Present -and $ownerState.StartMatches) {
    throw "Refusing recovery: owner process PID $ownerPid is still live. The lock was not changed."
}

$matchingDsh = @(Get-MatchingDshProcesses)
if ($matchingDsh.Count -gt 0) {
    $details = ($matchingDsh | ForEach-Object { "PID $($_.pid) $($_.name)" }) -join '; '
    throw "Refusing recovery: matching DeepSeek process(es) still running: $details. The lock was not changed."
}

$archiveRoot = Join-Path $controlRoot 'runs\stale-locks'
New-Item -ItemType Directory -Force -Path $archiveRoot | Out-Null
$archiveName = (Get-Date -Format 'yyyyMMdd-HHmmss-ffff') + '-' + $ownerPid
$archiveDirectory = Join-Path $archiveRoot $archiveName
New-Item -ItemType Directory -Path $archiveDirectory -ErrorAction Stop | Out-Null

$archivedLock = Join-Path $archiveDirectory 'run.lock'
Move-Item -LiteralPath $lockDirectory -Destination $archivedLock -ErrorAction Stop

$ownerActualStart = $null
if ($null -ne $ownerState.ActualStart) { $ownerActualStart = $ownerState.ActualStart.ToString('o') }

$recovery = [ordered]@{
    recovered_at = (Get-Date -Format o)
    recovered_by = 'Repair-DeepSeekLock.ps1'
    recovered_by_pid = $PID
    original_lock_path = $lockDirectory
    archived_lock_path = $archivedLock
    owner = $owner
    verification = [ordered]@{
        owner_pid = $ownerPid
        owner_process_present = $ownerState.Present
        owner_start_time_matches = $ownerState.StartMatches
        owner_actual_start = $ownerActualStart
        dsh_processes = @($matchingDsh)
        process_scan = 'Get-CimInstance Win32_Process'
    }
}
$recovery | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $archiveDirectory 'recovery.json') -Encoding utf8

if (-not (Test-Path -LiteralPath (Join-Path $archivedLock 'owner.json') -PathType Leaf)) {
    throw "Recovery moved the lock but the archived owner.json is missing. Inspect $archiveDirectory."
}
if (Test-Path -LiteralPath $lockDirectory) {
    throw "Recovery archived the lock but the live lock path still exists. Inspect $archiveDirectory."
}

Write-Output "Archived verified stale lock to $archivedLock"
Write-Output "Recovery evidence: $(Join-Path $archiveDirectory 'recovery.json')"
