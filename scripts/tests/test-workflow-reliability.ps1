# Offline regression tests. Extract functions without starting the supervisor.
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source = Join-Path $root 'scripts/agent-supervisor.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$null)
foreach ($name in @('Get-RecentSessions', 'Write-Utf8File')) {
    $node = $ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    . ([scriptblock]::Create($node.Extent.Text))
}
$statePath = Join-Path $env:TEMP ('workflow-regression-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $statePath | Out-Null
$logPath = Join-Path $statePath 'supervisor.log'
$script:failures = 0
function Check($name, $ok) {
    if ($ok) { Write-Output "PASS $name" } else { Write-Output "FAIL $name"; $script:failures++ }
}
function Get-ClaudeJsonlUsage($WorkDir, [datetime]$From, [datetime]$To) {
    return @{total = (100 + $From.Minute); cacheRead = 0}
}
function Get-CodexTokensFromLog($LogFile) { return 999 }
. (Join-Path $root 'scripts/lib/workflow-policy.ps1')
. (Join-Path $root 'scripts/lessons.ps1')
try {
    $day = (Get-Date).Date
    $first = $day.AddHours(1)
    $second = $day.AddHours(2).AddMinutes(5)
    $lines = @(
        "$($first.ToString('o')) [issue-271-revise-1] launching claude (edit) in C:\fixture, timeout 90 min",
        "$($first.AddMinutes(10).ToString('o')) [issue-271-revise-1] claude finished with exit 0",
        "$($second.ToString('o')) [issue-271-revise-1] launching claude (edit) in C:\fixture, timeout 90 min",
        "$($second.AddMinutes(20).ToString('o')) [issue-271-revise-1] claude finished with exit 0"
    )
    $cache = @{'issue-271-revise-1' = @{provider='claude'; tokens=100; finishedAt=$first.AddMinutes(10).ToString('o')}}
    Write-Utf8File (Join-Path $statePath 'sessions.json') ($cache | ConvertTo-Json)
    $sessions = @(Get-RecentSessions $day $lines)
    Check 'Repeated phase labels preserve both executions' ($sessions.Count -eq 2)
    Check 'Repeated phase labels never borrow prior execution tokens' (@($sessions | Where-Object {$_.tokens -eq 105}).Count -eq 1)
    Check 'Both durations survive' ((@($sessions.seconds | Sort-Object) -join ',') -eq '600,1200')
    $again = @(Get-RecentSessions $day $lines)
    Check 'Cache round trip preserves both executions' ($again.Count -eq 2 -and (@($again.tokens | Sort-Object) -join ',') -eq '100,105')

    # Legacy Codex files were overwritten. Only the latest run can use that file.
    $legacy = @($lines | ForEach-Object { $_.Replace('claude','codex').Replace('revise-1','review-3') })
    Write-Utf8File (Join-Path $statePath 'issue-271-review-3.output.md.log') 'placeholder'
    $sessions = @(Get-RecentSessions $day $legacy)
    Check 'Overwritten historical token files remain unknown' (@($sessions | Where-Object {$_.tokens -eq $null}).Count -eq 1)
    Check 'Latest legacy token file is attributable' (@($sessions | Where-Object {$_.tokens -eq 999}).Count -eq 1)
    Check 'Legacy cumulative corrections use all launches, not reset round' ((Get-LegacyRevisionCount 271 @{revisions=1} $lines) -eq 2)
    Check 'Legacy cumulative fallback preserves known attempts' ((Get-LegacyRevisionCount 271 @{revisions=9} @()) -eq 9)
    $quota = $lines + "$($second.AddMinutes(21).ToString('o')) [issue-271-revise-1] claude is out of quota"
    Check 'Quota refusal does not spend correction budget' ((Get-LegacyRevisionCount 271 @{revisions=0} $quota) -eq 1)
    $finding = 'movement-scheduling-load.test.js existing idle streak assertion is weakened'
    Check 'Empty findings are safe' (@(Get-FindingStreaks @('') @()).Count -eq 0)
    $other = 'Missing blue sky icon in the settings dialog'
    $streaks = @(Get-FindingStreaks @($finding) @())
    $streaks = @(Get-FindingStreaks @($finding, $other) $streaks)
    $resolved = @(Get-FindingStreaks @($other) $streaks)
    Check 'Changing overlapping findings do not falsely imply three repeats' ($resolved[0].repeats -eq 1)
    $persistent = @(Get-FindingStreaks @($finding, 'Different problem') $streaks)
    Check 'Same unresolved requirement survives new findings for three rounds' ($persistent[0].repeats -eq 2)
    Check 'Contradictory dependency header rejected before implementation' (@(Get-TaskContractFailures "Blocked by: none`n## Goal`nBlocked by: #265").Count -eq 1)
    Check 'Consistent existing tasks remain compatible' (@(Get-TaskContractFailures "Blocked by: #265`n## Goal`nBlocked by: #265").Count -eq 0)
} finally {
    # This path is a dedicated, newly-created child of TEMP, never caller supplied.
    $resolved = [IO.Path]::GetFullPath($statePath)
    $allowed = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\workflow-regression-'
    if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
if ($script:failures) { exit 1 }
Write-Output 'test-workflow-reliability: PASS'
