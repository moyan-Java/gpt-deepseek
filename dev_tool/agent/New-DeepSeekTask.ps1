[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot,

    [Parameter(Mandatory)]
    [string]$ControlRoot,

    [Parameter(Mandatory)]
    [string]$Title,

    [Parameter(Mandatory)]
    [string]$Goal,

    [Parameter(Mandatory)]
    [string[]]$Scope,

    [Parameter(Mandatory)]
    [string[]]$AcceptanceCriteria,

    [Parameter(Mandatory)]
    [string]$TestCommand
)

$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$controlRoot = [System.IO.Path]::GetFullPath($ControlRoot)
if (-not (Test-Path -LiteralPath $projectRoot -PathType Container)) {
    throw "ProjectRoot does not exist: $projectRoot"
}
New-Item -ItemType Directory -Force -Path $controlRoot | Out-Null
$taskPath = Join-Path $controlRoot 'TASK.md'

function Assert-RelativePath([string]$Path) {
    $normalized = $Path.Replace('\', '/').Trim()
    if ([string]::IsNullOrWhiteSpace($normalized) -or
        [System.IO.Path]::IsPathRooted($normalized) -or
        $normalized -match '(^|/)\.\.(/|$)') {
        throw "Allowed scope must be a project-relative path: $Path"
    }
    return $normalized
}

$scopeLines = foreach ($path in $Scope) { '- ' + (Assert-RelativePath $path) }
$acceptanceLines = foreach ($criterion in $AcceptanceCriteria) {
    if ([string]::IsNullOrWhiteSpace($criterion)) { throw 'Acceptance criteria cannot be blank.' }
    '- ' + $criterion.Trim()
}

$task = @"
# $Title

Task-ID: $([guid]::NewGuid().ToString())
Task-Status: ready
Test-Command: $TestCommand

## Goal

$Goal

## Allowed paths

$($scopeLines -join [Environment]::NewLine)

## Prohibited actions

- Do not read, print, create, or modify credentials, `.env` files, or user data.
- Do not modify files outside the allowed paths.
- Do not run `git reset`, `git clean`, `git commit`, or `git push`.
- Stop and report if the task requires a broader scope or interactive host-application access.

## Acceptance criteria

$($acceptanceLines -join [Environment]::NewLine)
"@

Set-Content -LiteralPath $taskPath -Value $task -Encoding utf8
Write-Output "Wrote reviewed task: $taskPath for target project: $projectRoot"
