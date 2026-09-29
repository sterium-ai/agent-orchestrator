<#
.SYNOPSIS
Self-test for scripts/lib/task-preflight.ps1 (Get-TaskPreflightAdditions, Add-OwnedPathsToBody,
Get-ForbiddenPathsFromBody, Get-PathsNamedInBlockedReport) and its wiring into
scripts/agent-supervisor.ps1.

.DESCRIPTION
Builds a throwaway worktree under $env:TEMP with sample test files, then asserts: a planner task
that was already widened gets no additions; a hand-written task gets the tests its owned files
imply; a task that owns the whole test folder gets none of them; the body edit keeps the rest of
the issue intact; paths named in a `## Blocked` report are returned only when they exist, are not
covered, are not protected and are not forbidden by the task's own text. Get-OwnedPaths and the
wiring checks read agent-supervisor.ps1 by AST.

Prints one line per check starting with PASS or FAIL, then a summary line, and exits non-zero
if any check failed.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"
$script:failCount = 0

function Test-Result([string]$Name, [bool]$Condition, [string]$Detail = "") {
    if ($Condition) {
        Write-Host "PASS $Name"
    } else {
        $line = "FAIL $Name"
        if ($Detail) { $line = "$line -- $Detail" }
        Write-Host $line
        $script:failCount++
    }
}

. (Resolve-Path (Join-Path $PSScriptRoot "..\lib\owned-paths-auto.ps1")).Path
. (Resolve-Path (Join-Path $PSScriptRoot "..\lib\task-preflight.ps1")).Path

function Get-FunctionSource([string]$Path, [string]$FunctionName) {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    $found = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName },
        $true
    ) | Select-Object -First 1
    if (-not $found) { throw "Could not find function '$FunctionName' in $Path via AST parsing." }
    return $found.Extent.Text
}

$supervisorPath = (Resolve-Path (Join-Path $PSScriptRoot "..\agent-supervisor.ps1")).Path
try {
    . ([scriptblock]::Create((Get-FunctionSource $supervisorPath "Get-OwnedPaths")))
} catch {
    Write-Host "FAIL Function extraction: Get-OwnedPaths (scripts/agent-supervisor.ps1) -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# The supervisor must dot-source the library and call the preflight before the author prompt is built.
$supervisorText = Get-Content -Path $supervisorPath -Raw
Test-Result "supervisor dot-sources task-preflight.ps1" ($supervisorText -match 'lib\\task-preflight\.ps1')
Test-Result "supervisor dot-sources trusted-authors.ps1" ($supervisorText -match 'lib\\trusted-authors\.ps1')
try {
    $impl = Get-FunctionSource $supervisorPath "Invoke-Implementation"
    $preflightAt = $impl.IndexOf('Get-TaskPreflightAdditions')
    $promptAt = $impl.IndexOf('Fill-Template (Get-TaskRole')
    $worktreeAt = $impl.IndexOf('New-AgentWorktree')
    Test-Result "Invoke-Implementation runs the preflight after the worktree exists and before the author prompt" (($preflightAt -gt $worktreeAt) -and ($promptAt -gt $preflightAt) -and ($worktreeAt -ge 0)) "worktree=$worktreeAt preflight=$preflightAt prompt=$promptAt"
    Test-Result "Invoke-Implementation passes the configured ownership rules to the preflight" ($impl -match 'Get-TaskPreflightAdditions[^\r\n]*-Rules \$script:OwnershipRules')
    $repair = Get-FunctionSource $supervisorPath "Invoke-Repair"
    Test-Result "Invoke-Repair honours add_owned_paths with every decision (Add-OwnedPathsToBody outside the rescope branch)" (($repair -match 'Add-OwnedPathsToBody') -and (([regex]::Matches($repair, 'add_owned_paths')).Count -ge 2))
    Test-Result "Invoke-Repair never grants a protected path" (([regex]::Matches($repair, 'Test-PathUnderForbidden -Path \$_ -Forbidden \$script:OwnershipRules.protectedPaths')).Count -ge 2)
    $review = Get-FunctionSource $supervisorPath "Invoke-Review"
    $freeRescopeAt = $review.IndexOf('Get-PathsNamedInBlockedReport')
    $repairCallAt = $review.IndexOf('Invoke-Repair $Issue "the author reports it cannot finish')
    Test-Result "Invoke-Review tries the free rescope from the Blocked report before the repair step" (($freeRescopeAt -ge 0) -and ($repairCallAt -gt $freeRescopeAt)) "rescope=$freeRescopeAt repair=$repairCallAt"
    $taskBodyRescopeAt = $review.IndexOf("named in a reviewer's task-body finding")
    $taskBodyRepairAt = $review.IndexOf('Invoke-Repair $Issue "the reviewer reports the task text is defective"')
    Test-Result "Invoke-Review tries the free rescope from a reviewer's task-body findings before the repair step" (($taskBodyRescopeAt -ge 0) -and ($taskBodyRepairAt -gt $taskBodyRescopeAt)) "rescope=$taskBodyRescopeAt repair=$taskBodyRepairAt"
    Test-Result "Invoke-Repair retries once when the repair reply has no usable decision" (($repair -match 'retrying once') -and ($repair -match 'repair-\$attempt-retry'))
    . ([scriptblock]::Create((Get-FunctionSource $supervisorPath "Extract-Json")))
    $trailing = "text before`n``````json`n{ `"decision`": `"hint`", `"patches`": [ { `"find`": `"a`", `"replace`": `"b`", } ], `"hint`": `"x`", }`n```````n"
    $parsedTrailing = Extract-Json $trailing
    Test-Result "Extract-Json tolerates trailing commas before a closing bracket" (($null -ne $parsedTrailing) -and ("$($parsedTrailing.decision)" -eq 'hint')) ("got: " + $(if ($parsedTrailing) { $parsedTrailing.decision } else { 'null' }))
    Test-Result "Extract-Json still rejects a truncated string" ($null -eq (Extract-Json "``````json`n{ `"decision`": `"hint`", `"hint`": `"unterminated`n}`n```````n"))
    $reportFailure = Get-FunctionSource $supervisorPath "Report-Failure"
    Test-Result "Report-Failure refreshes the owner's dashboard at once" ($reportFailure -match 'Register-FailureOnDashboard')
    $push = Get-FunctionSource $supervisorPath "Validate-And-Push"
    $prePushAt = $push.IndexOf('$PrePushCommand')
    $pushAt = $push.IndexOf('git push')
    Test-Result "Validate-And-Push runs the optional pre-push command before the push" (($prePushAt -ge 0) -and ($prePushAt -lt $pushAt)) "prePush=$prePushAt push=$pushAt"
} catch {
    Write-Host "FAIL Function extraction for wiring checks -- $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- fixture worktree

$testRoot = Join-Path $env:TEMP "test-task-preflight-$([Guid]::NewGuid().ToString('N'))"
$testsDir = Join-Path $testRoot "tests"
New-Item -ItemType Directory -Force -Path $testsDir | Out-Null
Set-Content -Path (Join-Path $testsDir "map_view.test.js") -Encoding utf8 -Value "import { MapView } from '../src/ui/map_view.js';"
Set-Content -Path (Join-Path $testsDir "unrelated.test.js") -Encoding utf8 -Value "import { X } from '../src/core/other.js';"
$rules = New-OwnershipRules @{ testDirectory = 'tests'; testFilter = '*.test.js'; protectedPaths = @('vendor/') }

try {
    # ------------------------------------------------------------------ preflight: additions

    $handWritten = @(
        'Provider: claude',
        'Reviewer: codex',
        'Role: implementer',
        'Objective: #345',
        'Blocked by: none',
        '',
        '## Goal',
        'Something the owner wrote by hand.',
        '',
        '## Owned paths',
        '- `src/ui/map_view.js`',
        '- `docs/decisions/`',
        '',
        '## Acceptance checks',
        '- [ ] it works'
    ) -join "`n"

    $adds = @(Get-TaskPreflightAdditions -Body $handWritten -WorktreeRoot $testRoot -IssueNumber 346 -OwnedPaths @(Get-OwnedPaths $handWritten) -Rules $rules)
    Test-Result "hand-written task: the test referencing its owned file is added" (($adds.Count -eq 1) -and ($adds[0].Path -eq 'tests/map_view.test.js') -and ($adds[0].Marker -eq '(auto: asserts on src/ui/map_view.js)')) ("got: " + (($adds | ForEach-Object { "$($_.Path) $($_.Marker)" }) -join '; '))
    Test-Result "without rules nothing is added" (@(Get-TaskPreflightAdditions -Body $handWritten -WorktreeRoot $testRoot -IssueNumber 346 -OwnedPaths @(Get-OwnedPaths $handWritten)).Count -eq 0)

    $widened = Add-OwnedPathsToBody -Body $handWritten -Additions $adds
    Test-Result "body edit appends the auto bullet inside ## Owned paths" ($widened -match '(?m)^- `docs/decisions/`\r?\n- `tests/map_view.test.js` \(auto: asserts on src/ui/map_view.js\)\r?\n\r?\n## Acceptance checks')
    Test-Result "body edit keeps the rest of the issue intact" (($widened.StartsWith('Provider: claude')) -and ($widened.EndsWith('- [ ] it works')))
    $reparsed = @(Get-OwnedPaths $widened)
    Test-Result "Get-OwnedPaths round-trips the widened body" (($reparsed.Count -eq 3) -and ($reparsed -contains 'tests/map_view.test.js'))

    $again = @(Get-TaskPreflightAdditions -Body $widened -WorktreeRoot $testRoot -IssueNumber 346 -OwnedPaths $reparsed -Rules $rules)
    Test-Result "preflight is idempotent: a widened body gets no further additions" ($again.Count -eq 0) ("got $($again.Count)")

    $ownsTestsDir = $handWritten.Replace('- `docs/decisions/`', '- `tests/`')
    $dirAdds = @(Get-TaskPreflightAdditions -Body $ownsTestsDir -WorktreeRoot $testRoot -IssueNumber 346 -OwnedPaths @(Get-OwnedPaths $ownsTestsDir) -Rules $rules)
    Test-Result "a task that owns tests/ gets no per-test bullets" ($dirAdds.Count -eq 0) ("got: " + (($dirAdds | ForEach-Object { $_.Path }) -join ', '))

    # ------------------------------------------------------------------ blocked-report paths
    New-Item -ItemType Directory -Force -Path (Join-Path $testRoot "src\core\registry") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $testRoot "src\core\jobs\givers") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $testRoot "content") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $testRoot "vendor\lib") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $testRoot "scripts") | Out-Null
    Set-Content -Path (Join-Path $testRoot "src\core\registry\content_registry.js") -Value 'export {}'
    Set-Content -Path (Join-Path $testRoot "content\objects.json") -Value '{}'
    Set-Content -Path (Join-Path $testRoot "vendor\lib\thing.js") -Value 'export {}'
    Set-Content -Path (Join-Path $testRoot "scripts\agent-supervisor.ps1") -Value '#'
    # Single-quoted here-string: in a double-quoted one a backtick before a letter would be read
    # as an escape and the path would never match.
    $blockedText = @'
- reason: out-of-scope
- the schema's build_cost.item needs a cross-reference check in
  `src/core/registry/content_registry.js`'s checkReferences() -- that file is not
  in Owned paths. A follow-up giver would live under src/core/jobs/givers/.
  Also mentions content/objects.json (already owned), docs/nowhere/missing.md (does not exist),
  vendor/lib/thing.js (protected), https://example.com/a/b (a URL)
  and scripts/agent-supervisor.ps1 (never).
'@
    $namedPaths = @(Get-PathsNamedInBlockedReport -Text $blockedText -WorktreeRoot $testRoot -OwnedPaths @('content/', 'src/ui/map_view.js') -Rules $rules)
    Test-Result "blocked report: an existing, uncovered file named in backticks is returned" ($namedPaths -contains 'src/core/registry/content_registry.js') ("got: " + ($namedPaths -join ', '))
    Test-Result "blocked report: an existing directory is returned with a trailing slash" ($namedPaths -contains 'src/core/jobs/givers/')
    Test-Result "blocked report: a file covered by an owned directory is skipped" (-not ($namedPaths | Where-Object { $_ -like '*objects.json' }))
    Test-Result "blocked report: a path that does not exist is skipped" (-not ($namedPaths | Where-Object { $_ -like '*missing.md' }))
    Test-Result "blocked report: a protected path is never returned" (-not ($namedPaths | Where-Object { $_ -like 'vendor/*' }))
    Test-Result "blocked report: the supervisor script is never returned" (-not ($namedPaths | Where-Object { $_ -like '*agent-supervisor*' }))
    Test-Result "blocked report: URLs are not mistaken for paths" (-not ($namedPaths | Where-Object { $_ -like '*example.com*' -or $_ -like 'a/b*' }))
    Test-Result "blocked report: nothing is returned for an empty text" (@(Get-PathsNamedInBlockedReport -Text '' -WorktreeRoot $testRoot -OwnedPaths @()).Count -eq 0)

    # ------------------------------------------------------------------ unowned generated files restored before the sweep
    $supervisorRaw = [IO.File]::ReadAllText($supervisorPath)
    $vapAt = $supervisorRaw.IndexOf('function Validate-And-Push(')
    $restoreCallAt = $supervisorRaw.IndexOf('Restore-UnownedGeneratedFiles -Worktree $Worktree', $vapAt)
    $sweepAt = $supervisorRaw.IndexOf('commit work left uncommitted by $Provider', $vapAt)
    Test-Result "Validate-And-Push restores unowned generated files before the uncommitted-work sweep" ($vapAt -ge 0 -and $restoreCallAt -gt $vapAt -and $sweepAt -gt $restoreCallAt)
    Test-Result "Restore-UnownedGeneratedFiles restores to the merge base, not to origin/main's tip" ($supervisorRaw.IndexOf('git merge-base origin/main HEAD') -ge 0 -and $supervisorRaw.IndexOf('git checkout $base -- $p') -ge 0)

    # ------------------------------------------------------------------ blocked-report paths vs the task's own Non-goals
    New-Item -ItemType Directory -Force -Path (Join-Path $testRoot "src\core\incidents") | Out-Null
    Set-Content -Path (Join-Path $testRoot "src\core\incidents\scheduler.js") -Value 'export {}'
    $scopedBody = @'
## Goal
Add the new content entries only.

## Non-goals
Do not modify src/core/combat/ or src/core/incidents/ -- report `## Blocked` instead.

## Owned paths
- `content/`
'@
    $forbidden = @(Get-ForbiddenPathsFromBody -Body $scopedBody)
    Test-Result "forbidden paths: a 'Do not modify <path>' sentence yields that path" ($forbidden -contains 'src/core/combat/') ("got: " + ($forbidden -join ', '))
    Test-Result "forbidden paths: every path in the sentence is collected" ($forbidden -contains 'src/core/incidents/')
    Test-Result "forbidden paths: an empty body yields nothing" (@(Get-ForbiddenPathsFromBody -Body '').Count -eq 0)
    $coreBlocked = @'
- reason: out-of-scope
- Scheduler.onJobFinished() in src/core/incidents/scheduler.js despawns the actor; needs a change there and in src/core/registry/content_registry.js.
'@
    $namedCore = @(Get-PathsNamedInBlockedReport -Text $coreBlocked -WorktreeRoot $testRoot -OwnedPaths @('content/') -TaskBody $scopedBody -Rules $rules)
    Test-Result "blocked report naming a forbidden file returns nothing at all (scope decision, not a free rescope)" ($namedCore.Count -eq 0) ("got: " + ($namedCore -join ', '))
    $namedNoBody = @(Get-PathsNamedInBlockedReport -Text $coreBlocked -WorktreeRoot $testRoot -OwnedPaths @('content/') -Rules $rules)
    Test-Result "the same report without a task body still names the files" ($namedNoBody -contains 'src/core/incidents/scheduler.js')
    $areaBlocked = @'
- reason: out-of-scope
- needs tests/ (several tests) and src/core/jobs/givers/ for the giver.
'@
    $namedArea = @(Get-PathsNamedInBlockedReport -Text $areaBlocked -WorktreeRoot $testRoot -OwnedPaths @('content/') -Rules $rules)
    Test-Result "a whole top-level folder like tests/ is never granted by a rescope" (-not ($namedArea -contains 'tests/')) ("got: " + ($namedArea -join ', '))
    Test-Result "a deeper subfolder is still granted" ($namedArea -contains 'src/core/jobs/givers/')

    $noSection = ($handWritten -replace '(?ms)## Owned paths.*?(?=## Acceptance)', '')
    Test-Result "a body without ## Owned paths is left alone (null) instead of invented" ($null -eq (Add-OwnedPathsToBody -Body $noSection -Additions $adds))
    Test-Result "no additions returns the body unchanged" ((Add-OwnedPathsToBody -Body $handWritten -Additions @()) -eq $handWritten)
} catch {
    Write-Host "FAIL Task-preflight checks -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
} finally {
    Remove-Item -Recurse -Force -Path $testRoot -ErrorAction SilentlyContinue
}

if ($script:failCount -gt 0) {
    Write-Host "SUMMARY: $script:failCount check(s) failed"
    exit 1
}
Write-Host "SUMMARY: all checks passed"
exit 0
