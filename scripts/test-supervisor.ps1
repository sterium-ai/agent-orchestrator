<#
.SYNOPSIS
Self-test for the pure helper functions in scripts/agent-supervisor.ps1 and scripts/run-agent.ps1.

.DESCRIPTION
Exercises Get-Field, Get-IssueRefs, Extract-Json, Load-State, Save-State, Fill-Template,
Other-Provider, Read-Handoff and Get-QuotaBlock as black boxes, without touching GitHub,
launching any agent, or dot-sourcing either script directly (the bottom of
agent-supervisor.ps1 requires the GitHub CLI, checks a lock file, and enters an infinite poll loop).
Instead, each function's source is located with the PowerShell AST and defined in this
script's own scope from its extent text.

Prints one line per check starting with PASS or FAIL, then a summary line, and exits
non-zero if any check failed. Every section (function extraction, each helper's checks, and
the -DryRun smoke check) runs inside its own try/catch, all at this script's top-level scope
(deliberately NOT inside a nested function or scriptblock -- Load-State/Save-State/Fill-Template
read/write the bare $statePath/$promptDir variables via their own lexical (top-level) scope
chain, the same way they do in agent-supervisor.ps1 itself, so the test code that sets those
variables must run in that same top-level scope for the linkage to work). An unexpected
exception (e.g. a temp directory that cannot be created) is converted into a labelled FAIL
instead of silently aborting the section or crashing the whole script. After all sections run,
this script also verifies that every required helper actually produced at least one PASS/FAIL
line -- if a section aborted early and skipped some of its checks, that is reported as an
explicit FAIL rather than allowed to produce a false-positive summary.

.PARAMETER DryRun
Additionally launches ``agent-supervisor.ps1 -DryRun -Once`` with a short timeout as a
smoke check. Reports PASS if it starts and exits cleanly, or SKIP (never a false PASS)
when the GitHub CLI is missing or not authenticated -- agent-supervisor.ps1 requires both
at startup even in -DryRun mode. An unexpected error in this section (e.g. the subprocess
failing to start at all) is reported as FAIL rather than silently skipped.
#>
[CmdletBinding()]
param(
    [switch]$DryRun
)

# "Continue", not "Stop": in Windows PowerShell 5.1, native stderr (e.g. from the GitHub CLI
# in the -DryRun path below) becomes a terminating error under "Stop" -- same reason
# agent-supervisor.ps1 itself sets this. Every section below still has its own try/catch so
# genuine terminating errors (thrown .NET exceptions, missing commands) are still caught and
# reported as FAIL instead of escaping silently.
$ErrorActionPreference = "Continue"
$script:failCount = 0
$script:executedNames = New-Object System.Collections.Generic.List[string]

function Test-Result([string]$Name, [bool]$Condition, [string]$Detail = "") {
    $script:executedNames.Add($Name)
    if ($Condition) {
        Write-Host "PASS $Name"
    } else {
        $line = "FAIL $Name"
        if ($Detail) { $line = "$line -- $Detail" }
        Write-Host $line
        $script:failCount++
    }
}

# Save-State's error path (see below) calls Write-Log, which in agent-supervisor.ps1 depends
# on module-level state ($statePath/$logPath) this script deliberately never initialises --
# extracting the real Write-Log would either no-op incorrectly or throw. A local no-op stub
# is enough: this test only asserts Save-State's return value, never Write-Log's side effects,
# and without this stub an unwritable destination would turn "Save-State reports failure"
# into an uncaught "command not found" error instead.
function Write-Log([string]$Message) { }

# ----------------------------------------------------------------------------- function extraction
# AST-based extraction: parses the file's text without executing it, finds the named
# FunctionDefinitionAst, and returns its exact source text. Dot-sourcing that text as a
# scriptblock defines only that function, in this script's scope -- nothing else in the
# source file (module-level startup/lock/poll-loop code) ever runs.
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

$supervisorPath = Join-Path $PSScriptRoot "agent-supervisor.ps1"
$runAgentPath = Join-Path $PSScriptRoot "run-agent.ps1"

# Each function is extracted independently: one missing/renamed function must not stop the
# others from being defined. Any helper whose extraction fails simply stays undefined; the
# section(s) that call it will then fail with "command not found", which the required-check
# verification at the end converts into an explicit FAIL for that helper's name.
# Normalize-Provider/Get-OtherProviders read the script-level provider list; define it here the
# same way agent-supervisor.ps1 does, since only functions are extracted below.
$script:AllProviders = @("claude", "codex", "copilot")
$CodexAccountsDir = Join-Path $env:TEMP "test-supervisor-no-such-codex-accounts-dir"
foreach ($fn in @("Get-Field", "Get-IssueRefs", "Read-Handoff", "Load-State", "Save-State", "Fill-Template", "Extract-Json", "Other-Provider", "Normalize-Provider", "Get-OtherProviders", "Get-IssueProviders", "Get-ProviderState", "Get-AccountCooldown", "Get-ProviderAccounts", "Get-ReadyAccount", "Get-ProviderCooldown", "Test-ProviderReady", "Set-ProviderCooldown", "Require-Command", "Test-ProviderUsable", "Get-EffectiveReviewer", "Test-ReviewRunnable", "Get-OwnedPaths", "Get-TaskReasoning", "Limit-Text", "Get-AcceptanceCommands", "Resolve-AcceptanceCommand", "Get-AcceptanceCommandDefect", "Get-FailureSignature", "Get-FailureClass", "Get-HandoffBlock", "Write-Utf8File", "Test-QueueLabelsStale", "Test-OrphanChain", "Test-OrphanCandidate", "Select-LeakedHolders", "Initialize-ProcessInterop", "Get-FileHolders")) {
    try {
        . ([scriptblock]::Create((Get-FunctionSource $supervisorPath $fn)))
    } catch {
        Write-Host "FAIL Function extraction: $fn (scripts/agent-supervisor.ps1) -- unexpected error: $($_.Exception.Message)"
        $script:failCount++
    }
}
try {
    . ([scriptblock]::Create((Get-FunctionSource $runAgentPath "Get-QuotaBlock")))
} catch {
    Write-Host "FAIL Function extraction: Get-QuotaBlock (scripts/run-agent.ps1) -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}
try {
    . ([scriptblock]::Create((Get-FunctionSource $supervisorPath "Get-RecentSessions")))
} catch {
    Write-Host "FAIL Function extraction: Get-RecentSessions (scripts/agent-supervisor.ps1) -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}
# Get-TaskRole/Get-AgentCommonSection live in their own dot-sourceable module, unlike the
# functions above: dot-source the real file (not an AST extraction) so Get-AgentCommonSection's
# $PSScriptRoot resolves to scripts/lib, exactly as it does when agent-supervisor.ps1 dot-sources it.
try {
    . (Join-Path $PSScriptRoot "lib\role-select.ps1")
} catch {
    Write-Host "FAIL Function extraction: Get-TaskRole/Get-AgentCommonSection (scripts/lib/role-select.ps1) -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Get-Field
try {
    $sampleBody = @"
Provider: claude
Reviewer: codex
Objective: #11
Blocked by: #12

## Goal
Do the thing.
"@
    Test-Result "Get-Field: extracts an existing field's value" ((Get-Field $sampleBody "Provider") -eq "claude")
    Test-Result "Get-Field: returns null for a field that is not present" ($null -eq (Get-Field $sampleBody "NoSuchField"))
} catch {
    Write-Host "FAIL Get-Field -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Get-TaskRole / Get-AgentCommonSection
try {
    Test-Result "Get-TaskRole: defaults to implementer when there is no Role: line" ((Get-TaskRole $sampleBody) -eq "implementer")
    Test-Result "Get-TaskRole: defaults to implementer for an unrecognised role" ((Get-TaskRole "Provider: claude`nRole: bogus`n") -eq "implementer")
    # A role selects <role>.md in the prompt templates directory, when that file exists.
    $rolePromptDir = Join-Path $env:TEMP ("test-supervisor-roles-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $rolePromptDir | Out-Null
    Set-Content -Path (Join-Path $rolePromptDir "docs-writer.md") -Value "fixture" -Encoding ascii
    Set-Content -Path (Join-Path $rolePromptDir "reviewer.md") -Value "fixture" -Encoding ascii
    try {
        Test-Result "Get-TaskRole: a role with its own prompt file is selected" ((Get-TaskRole "Provider: claude`nRole: docs-writer`n" $rolePromptDir) -eq "docs-writer")
        Test-Result "Get-TaskRole: is case-insensitive" ((Get-TaskRole "Role: DOCS-WRITER" $rolePromptDir) -eq "docs-writer")
        Test-Result "Get-TaskRole: a role without a prompt file falls back to implementer" ((Get-TaskRole "Role: artist" $rolePromptDir) -eq "implementer")
        Test-Result "Get-TaskRole: a reserved prompt name can never be selected as an author role" ((Get-TaskRole "Role: reviewer" $rolePromptDir) -eq "implementer")
        Test-Result "Get-TaskRole: a role that is not a plain name falls back to implementer" ((Get-TaskRole "Role: ..\docs-writer" $rolePromptDir) -eq "implementer")
    } finally { Remove-Item -Recurse -Force -LiteralPath $rolePromptDir -ErrorAction SilentlyContinue }

    $commonSection = Get-AgentCommonSection
    Test-Result "Get-AgentCommonSection: reads docs/agent-prompts/_agent-common.md and includes the Handoff heading" ($commonSection -match '## Handoff \(mandatory\)')
    Test-Result "Get-AgentCommonSection: includes the Blocked rule text" ($commonSection -match '## Blocked')
} catch {
    Write-Host "FAIL Get-TaskRole / Get-AgentCommonSection -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Resolve-AcceptanceCommand
try {
    $nested = 'powershell -NoProfile -Command "$c = Get-Content -Raw docs\x.html; if ($c -notmatch ''y'') { exit 1 }"'
    $r = Resolve-AcceptanceCommand $nested
    Test-Result "Resolve-AcceptanceCommand: unwraps nested powershell -Command to its inner text" ($r.Rewritten -and $r.Command -eq '$c = Get-Content -Raw docs\x.html; if ($c -notmatch ''y'') { exit 1 }')
    Test-Result "Resolve-AcceptanceCommand: keeps the original line for the transcript" ($r.Original -eq $nested)
    $r2 = Resolve-AcceptanceCommand 'powershell.exe -NoProfile -ExecutionPolicy Bypass -c "$errs=$null; exit 0"'
    Test-Result "Resolve-AcceptanceCommand: handles -c and flags with values" ($r2.Rewritten -and $r2.Command -eq '$errs=$null; exit 0')
    $r3 = Resolve-AcceptanceCommand 'powershell -NoProfile -Command "Write-Output \"a b\"; exit 0"'
    Test-Result "Resolve-AcceptanceCommand: unescapes \`" inside the quoted text" ($r3.Rewritten -and $r3.Command -eq 'Write-Output "a b"; exit 0')
    Test-Result "Resolve-AcceptanceCommand: leaves powershell -File alone" (-not (Resolve-AcceptanceCommand 'powershell -NoProfile -File scripts\test-supervisor.ps1').Rewritten)
    Test-Result "Resolve-AcceptanceCommand: leaves a plain expression alone" (-not (Resolve-AcceptanceCommand 'if ((Get-Content -Raw f) -notmatch ''y'') { exit 1 }').Rewritten)
    Test-Result "Resolve-AcceptanceCommand: does not unwrap when arguments follow the closing quote" (-not (Resolve-AcceptanceCommand 'powershell -Command "$x = 1" -NoProfile').Rewritten)
    Test-Result "Get-AcceptanceCommandDefect: null for an unwrappable line (it is fixed, not a defect)" ($null -eq (Get-AcceptanceCommandDefect $nested))
    Test-Result "Get-AcceptanceCommandDefect: flags a nested `$ line that cannot be unwrapped" ($null -ne (Get-AcceptanceCommandDefect 'powershell -Command "$x = 1" -NoProfile'))
    Test-Result "Get-AcceptanceCommandDefect: accepts powershell -File" ($null -eq (Get-AcceptanceCommandDefect 'powershell -NoProfile -File scripts\test-supervisor.ps1'))
    Test-Result "Get-AcceptanceCommandDefect: null for an empty line" ($null -eq (Get-AcceptanceCommandDefect ''))
    # Copilot free plan, observed 2026-09-19: monthly quota, no reset time in the text.
    $cpq = Get-QuotaBlock "`nYou have exceeded your monthly quota (Request ID: E9F8:328A7A:EA265E:10A2A25:6AADCF1A)`n"
    $firstOfNext = (Get-Date -Day 1 -Hour 0 -Minute 0 -Second 0).AddMonths(1)
    Test-Result "Get-QuotaBlock: Copilot 'exceeded your monthly quota' is a quota block that resets on the 1st of next month" (
        $cpq -and $cpq.Until -and $cpq.Until.Date -eq $firstOfNext.Date -and $cpq.Message -like "*monthly quota*"
    )
    $bodyWithComment = "## Acceptance commands`n" + '```powershell' + "`n# NOT RUNNABLE, disabled by the supervisor because x -- original line: $nested`npowershell -NoProfile -File scripts\a.ps1`n" + '```'
    $extracted = @(Get-AcceptanceCommands $bodyWithComment)
    Test-Result "Get-AcceptanceCommands: a disabled (#) line is skipped and the rest kept" ($extracted.Count -eq 1 -and $extracted[0] -eq 'powershell -NoProfile -File scripts\a.ps1')

    # Failure identity: the same wall must hash alike across commits, times and durations
    # (an author can commit something cosmetic every round while the failure stays identical);
    # a different failure must not.
    $wallA = "Acceptance command failed (exit 1): ``node scripts\start-server.js``  (exit 1, 2.3s)`nError: listen EADDRINUSE: address already in use :::8080 at 2026-09-16T12:01:05.123+00:00 commit a1b2c3d4e5f"
    $wallB = "Acceptance command failed (exit 1): ``node scripts\start-server.js``  (exit 1, 41.9s)`nError: listen EADDRINUSE: address already in use :::8080 at 2026-09-16T13:47:59.001+00:00 commit ffeeddccbba"
    $other = "Acceptance command failed (exit 1): ``powershell -NoProfile -File scripts\test-x.ps1``  (exit 1, 2.3s)`nFAIL expected 3 got 4"
    Test-Result "Get-FailureSignature: same failure, different commit/time/duration -> same signature" ((Get-FailureSignature @($wallA)) -eq (Get-FailureSignature @($wallB)))
    Test-Result "Get-FailureSignature: a different failure -> a different signature" ((Get-FailureSignature @($wallA)) -ne (Get-FailureSignature @($other)))
    Test-Result "Get-FailureSignature: order of failures does not matter" ((Get-FailureSignature @($wallA, $other)) -eq (Get-FailureSignature @($other, $wallB)))
    Test-Result "Get-FailureSignature: empty for no failures" ((Get-FailureSignature @()) -eq "")

    Test-Result "Get-FailureClass: port in use is an environment failure" (([string](Get-FailureClass $wallA)) -like "environment:*")
    Test-Result "Get-FailureClass: a timed-out command is an environment failure" (([string](Get-FailureClass "Acceptance command failed (exit -2): ``x``  (exit -2, 300s)`nworking...`n[timed out after 300 s and was killed]")) -like "environment:*")
    Test-Result "Get-FailureClass: a refused command is a task-body failure" (([string](Get-FailureClass "Acceptance command failed (exit -1): ``git push```nrefused: this command matches a pattern the supervisor will not run from an issue body")) -like "task-body:*")
    Test-Result "Get-FailureClass: a command that does not parse is a task-body failure" (([string](Get-FailureClass "Acceptance command failed (exit 1): ``if (`$c -eq) { }```nAt line:1 char:9`nMissing expression after ')'.`n    + CategoryInfo          : ParserError: (:) [], ParseException")) -like "task-body:*")
    Test-Result "Get-FailureClass: an ordinary failing test is the author's" ($null -eq (Get-FailureClass $other))
    Test-Result "Get-FailureClass: a parse error in a changed .ps1 is the author's" ($null -eq (Get-FailureClass "``scripts\x.ps1`` does not parse under Windows PowerShell 5.1 (1 error(s)):`nline 3: Missing closing '}' in statement block"))

    $blockedHandoff = "## Branch`nagent/issue-71`n`n## Blocked`nreason: environment`nPort 8080 is held by another process on the host; the test server cannot bind.`n`n## Next action`nnone"
    $b = Get-HandoffBlock $blockedHandoff
    Test-Result "Get-HandoffBlock: parses a ## Blocked section (reason + detail)" ($b -and $b.Reason -eq "environment" -and $b.Detail -like "Port 8080*bind.")
    $b2 = Get-HandoffBlock "## Known limitations`n- SCOPE-BLOCKED: docs/architecture/save-system.md -- deferred to task 5`n## Next action`nnone"
    Test-Result "Get-HandoffBlock: a SCOPE-BLOCKED note under Known limitations is bookkeeping, not a block" ($null -eq $b2)
    $b3 = Get-HandoffBlock "## Blocked`nreason: out-of-scope`nscripts/run-agent.ps1 -- the finding needs the runner`n`n## Known limitations`n- left untouched (out of scope): docs/x.md -- another task owns it`n## Next action`nnone"
    Test-Result "Get-HandoffBlock: a real out-of-scope block is still read when written as the section" ($b3 -and $b3.Reason -eq "out-of-scope" -and $b3.Detail -like "scripts/run-agent.ps1*")
    Test-Result "Get-HandoffBlock: null for a handoff without a block" ($null -eq (Get-HandoffBlock "## Branch`nx`n## Known limitations`nnone`n## Next action`nnone"))
    Test-Result "Get-HandoffBlock: an unknown reason is not a block" ($null -eq (Get-HandoffBlock "## Blocked`nreason: tired`nno"))
} catch {
    Write-Host "FAIL Resolve-AcceptanceCommand -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Get-IssueRefs
try {
    Test-Result "Get-IssueRefs: extracts every #123-style reference" ((@(Get-IssueRefs "See #11 and also #12, then #007") -join ",") -eq "11,12,7")
    Test-Result "Get-IssueRefs: returns none when there are no references" (@(Get-IssueRefs "no references in this text").Count -eq 0)
} catch {
    Write-Host "FAIL Get-IssueRefs -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Extract-Json
try {
    $fencedText = @'
Here is the plan:
```json
{"summary": "ok", "count": 2}
```
Thanks.
'@
    $fenced = Extract-Json $fencedText
    Test-Result "Extract-Json: recovers the JSON object from a fenced ```json block" ($fenced -and $fenced.summary -eq "ok" -and $fenced.count -eq 2)

    $bareJson = Extract-Json 'prefix noise {"verdict": "approve", "n": 5} trailing noise'
    Test-Result "Extract-Json: recovers a bare JSON object with no fence" ($bareJson -and $bareJson.verdict -eq "approve" -and $bareJson.n -eq 5)

    Test-Result "Extract-Json: returns null for truncated/malformed JSON" ($null -eq (Extract-Json '{"summary": "cut off", "tasks": [ {"title": "a"'))
} catch {
    Write-Host "FAIL Extract-Json -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Load-State / Save-State
# Deliberately at top-level scope (not inside a function/scriptblock): Load-State and
# Save-State, as extracted from agent-supervisor.ps1, read/write the bare $statePath variable
# via their own lexical (definition-site) scope chain, which is this script's top-level scope.
# Setting $statePath from inside a nested function/scriptblock would create it in that nested
# scope instead, which those functions would never see.
try {
    $tempStateDir = Join-Path $env:TEMP "test-supervisor-state-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $tempStateDir -ErrorAction Stop | Out-Null
    try {
        $statePath = $tempStateDir

        $ok1 = $null
        $defaults = Load-State 999001 ([ref]$ok1)
        Test-Result "Load-State: returns defaults when no state file exists yet" (
            $ok1 -eq $true -and $defaults.revisions -eq 0 -and $defaults.escalated -eq $false -and
            $defaults.reviewFailures -eq 0 -and $defaults.pendingPush -eq $false
        )

        $toSave = @{ revisions = 3; escalated = $true; reviewFailures = 1; pendingPush = $true; note = "round-trip" }
        $saveOk = Save-State 999001 $toSave
        Test-Result "Save-State: writes state and reports success" ($saveOk -eq $true)

        $ok2 = $null
        $reloaded = Load-State 999001 ([ref]$ok2)
        Test-Result "Load-State: round-trips a hashtable saved by Save-State" (
            $ok2 -eq $true -and $reloaded.revisions -eq 3 -and $reloaded.escalated -eq $true -and
            $reloaded.reviewFailures -eq 1 -and $reloaded.pendingPush -eq $true -and $reloaded.note -eq "round-trip"
        )

        # Test-ReviewRunnable reads the same state files. No providers file exists in this temp
        # dir, so nothing is on cooldown; "usable" then reduces to Require-Command, which finds
        # `powershell` on any Windows host and never finds the made-up name.
        $providersPath = Join-Path $tempStateDir "providers.json"
        $issueRunnable = [pscustomobject]@{ number = 999002; body = "Provider: claude`nReviewer: codex`n" }
        Save-State 999002 @{ awaitingRevisionBy = "powershell" } | Out-Null
        Test-Result "Test-ReviewRunnable: an owed revision is runnable when its author is usable" ((Test-ReviewRunnable $issueRunnable) -eq $true)
        Save-State 999002 @{ awaitingRevisionBy = "no-such-provider-xyz" } | Out-Null
        Test-Result "Test-ReviewRunnable: an owed revision waits while its author is unusable, even if a reviewer is" ((Test-ReviewRunnable $issueRunnable) -eq $false)

        # Reserve Codex logins: a subfolder of $CodexAccountsDir counts only once it holds an
        # auth.json (the owner has run `codex login` into it). Cooldowns are per login; the
        # provider rests only when every login does.
        $CodexAccountsDir = Join-Path $tempStateDir "codex-accounts"
        New-Item -ItemType Directory -Force -Path (Join-Path $CodexAccountsDir "b") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $CodexAccountsDir "not-logged-in") | Out-Null
        Set-Content -Path (Join-Path $CodexAccountsDir "b\auth.json") -Value "{}" -Encoding ascii
        $logins = @(Get-ProviderAccounts "codex")
        Test-Result "Get-ProviderAccounts: primary first, then only the reserve folders that are logged in" (
            $logins.Count -eq 2 -and $logins[0].key -eq "codex" -and $null -eq $logins[0].codexHome -and
            $logins[1].key -eq "codex/b" -and $logins[1].label -eq "b" -and $logins[1].codexHome -eq (Join-Path $CodexAccountsDir "b")
        )
        Test-Result "Get-ProviderAccounts: other providers have just their primary login" (@(Get-ProviderAccounts "claude").Count -eq 1 -and @(Get-ProviderAccounts "copilot").Count -eq 1)
        Test-Result "Get-ReadyAccount: the primary login is used while it has quota" ((Get-ReadyAccount "codex").key -eq "codex")
        Set-ProviderCooldown "codex" (Get-Date).AddHours(2) "hit your usage limit"
        Test-Result "Get-ReadyAccount: the reserve login takes over when the primary is out, so the provider stays ready" (
            (Get-ReadyAccount "codex").key -eq "codex/b" -and (Test-ProviderReady "codex") -eq $true -and (Test-ProviderUsable "codex") -eq [bool](Require-Command "codex")
        )
        Set-ProviderCooldown "codex/b" (Get-Date).AddHours(1) "hit your usage limit"
        $rest = Get-ProviderCooldown "codex"
        Test-Result "Get-ProviderCooldown: with every login out, the provider rests until the EARLIEST reset" (
            $null -eq (Get-ReadyAccount "codex") -and (Test-ProviderReady "codex") -eq $false -and $rest -and ($rest - (Get-Date)).TotalMinutes -lt 75
        )
        Test-Result "Get-AccountCooldown: a login's cooldown never leaks onto another provider" ($null -eq (Get-AccountCooldown "claude") -and (Test-ProviderReady "claude") -eq $true)
        Remove-Item $providersPath -Force -ErrorAction SilentlyContinue
        $CodexAccountsDir = Join-Path $env:TEMP "test-supervisor-no-such-codex-accounts-dir"
    } finally {
        Remove-Item -Recurse -Force $tempStateDir -ErrorAction SilentlyContinue
    }
} catch {
    Write-Host "FAIL Load-State / Save-State -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Fill-Template
# Also deliberately at top-level scope: Fill-Template resolves $promptDir the same way.
try {
    $tempPromptDir = Join-Path $env:TEMP "test-supervisor-prompts-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $tempPromptDir -ErrorAction Stop | Out-Null
    try {
        $promptDir = $tempPromptDir
        $templatePath = Join-Path $tempPromptDir "sample.md"
        [System.IO.File]::WriteAllText($templatePath, "Hello {{NAME}}, task {{NUMBER}}. Untouched: {{NOT_PROVIDED}}.", (New-Object System.Text.UTF8Encoding($false)))

        $filled = Fill-Template "sample" @{ NAME = "Claude"; NUMBER = "#13" }
        Test-Result "Fill-Template: substitutes one or more {{KEY}} placeholders" ($filled -eq "Hello Claude, task #13. Untouched: {{NOT_PROVIDED}}.")
        Test-Result "Fill-Template: leaves unknown placeholder text untouched" ($filled -match [regex]::Escape("{{NOT_PROVIDED}}"))
    } finally {
        Remove-Item -Recurse -Force $tempPromptDir -ErrorAction SilentlyContinue
    }
} catch {
    Write-Host "FAIL Fill-Template -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Other-Provider
try {
    Test-Result "Other-Provider: maps claude to codex" ((Other-Provider "claude") -eq "codex")
    Test-Result "Other-Provider: maps codex to claude" ((Other-Provider "codex") -eq "claude")
    Test-Result "Other-Provider: a copilot author defaults to a claude reviewer" ((Other-Provider "copilot") -eq "claude")
    Test-Result "Normalize-Provider: accepts the three providers case-insensitively" (((Normalize-Provider " Codex ") -eq "codex") -and ((Normalize-Provider "COPILOT") -eq "copilot") -and ((Normalize-Provider "claude") -eq "claude"))
    Test-Result "Normalize-Provider: anything else falls back to claude" (((Normalize-Provider "") -eq "claude") -and ((Normalize-Provider "gemini") -eq "claude"))
    Test-Result "Get-OtherProviders: never contains the provider itself and lists both others" (
        ((Get-OtherProviders "claude") -join ",") -eq "codex,copilot" -and
        ((Get-OtherProviders "codex") -join ",") -eq "claude,copilot" -and
        ((Get-OtherProviders "copilot") -join ",") -eq "claude,codex")
    # Get-IssueProviders only needs Get-Field (already extracted) plus the helpers above.
    $issueCopilot = [pscustomobject]@{ body = "Provider: copilot`nReviewer: codex`n" }
    $ip = Get-IssueProviders $issueCopilot
    Test-Result "Get-IssueProviders: honours copilot as author and an explicit different reviewer" (($ip.Author -eq "copilot") -and ($ip.Reviewer -eq "codex"))
    $issueSame = [pscustomobject]@{ body = "Provider: claude`nReviewer: claude`n" }
    $ip2 = Get-IssueProviders $issueSame
    Test-Result "Get-IssueProviders: a reviewer equal to the author is replaced by the default partner" (($ip2.Author -eq "claude") -and ($ip2.Reviewer -eq "codex"))
} catch {
    Write-Host "FAIL Other-Provider -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Read-Handoff
try {
    $tempWorktree = Join-Path $env:TEMP "test-supervisor-worktree-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $tempWorktree -ErrorAction Stop | Out-Null
    try {
        $noHandoff = Read-Handoff $tempWorktree
        Test-Result "Read-Handoff: returns the not-written fallback message when neither file exists" ($noHandoff -match "did not write a handoff")

        $rootHandoffPath = Join-Path $tempWorktree "HANDOFF.md"
        [System.IO.File]::WriteAllText($rootHandoffPath, "Root-level handoff.", (New-Object System.Text.UTF8Encoding($false)))
        $rootHandoff = Read-Handoff $tempWorktree
        # $rootHandoff is guarded with "-and" (which short-circuits in PowerShell) before .Trim()
        # is called on it: if Read-Handoff ever regressed to returning $null here, calling .Trim()
        # unguarded on $null would throw a "method on a null-valued expression" error. That error
        # is now caught by this section's try/catch and reported as a labelled FAIL (instead of
        # silently vanishing under $ErrorActionPreference = "Continue").
        Test-Result "Read-Handoff: falls back to a root-level HANDOFF.md" ($rootHandoff -and $rootHandoff.Trim() -eq "Root-level handoff.")

        $stateDir = Join-Path $tempWorktree ".agent-state"
        New-Item -ItemType Directory -Force -Path $stateDir -ErrorAction Stop | Out-Null
        $preferredHandoffPath = Join-Path $stateDir "HANDOFF.md"
        # UTF8Encoding($true) writes a leading BOM, matching what an agent CLI may produce.
        [System.IO.File]::WriteAllText($preferredHandoffPath, "Preferred handoff.", (New-Object System.Text.UTF8Encoding($true)))
        $preferredHandoff = Read-Handoff $tempWorktree
        Test-Result "Read-Handoff: prefers .agent-state/HANDOFF.md over the root fallback, and strips a leading BOM" (
            $preferredHandoff -and $preferredHandoff.Trim() -eq "Preferred handoff." -and $preferredHandoff.Length -gt 0 -and [int]$preferredHandoff[0] -ne 0xFEFF
        )
    } finally {
        Remove-Item -Recurse -Force $tempWorktree -ErrorAction SilentlyContinue
    }
} catch {
    Write-Host "FAIL Read-Handoff -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Get-QuotaBlock
try {
    $claudeQuotaText = "You've hit your session limit " + [char]0x00B7 + " resets 5:30pm (America/New_York)"
    $claudeQuota = Get-QuotaBlock $claudeQuotaText
    Test-Result "Get-QuotaBlock: recognises the claude session-limit message and parses the reset time" (
        $claudeQuota -and $claudeQuota.Until -and $claudeQuota.Until.Hour -eq 17 -and $claudeQuota.Until.Minute -eq 30
    )

    $codexQuotaText = "ERROR: You've hit your usage limit. Upgrade your plan or try again at 7:51 PM."
    $codexQuota = Get-QuotaBlock $codexQuotaText
    Test-Result "Get-QuotaBlock: recognises the codex usage-limit message and parses the reset time" (
        $codexQuota -and $codexQuota.Until -and $codexQuota.Until.Hour -eq 19 -and $codexQuota.Until.Minute -eq 51
    )

    $ordinaryText = "Our public API documentation mentions a rate limit for fairness; this sentence is not an error."
    Test-Result "Get-QuotaBlock: returns null for ordinary text that merely mentions a rate limit" ($null -eq (Get-QuotaBlock $ordinaryText))

    $copilotQuotaText = "Error: You have exhausted your premium requests for this month. Upgrade or wait for your monthly allowance to reset."
    $copilotQuota = Get-QuotaBlock $copilotQuotaText
    Test-Result "Get-QuotaBlock: recognises a copilot premium-request exhaustion message (monthly: resets on the 1st)" (
        $copilotQuota -and $copilotQuota.Until -and $copilotQuota.Until.Day -eq 1 -and $copilotQuota.Until -gt (Get-Date) -and $copilotQuota.Message -match "premium requests"
    )
    $copilotOrdinary = "The task mentions premium requests as a concept in the docs; nothing is exhausted here."
    Test-Result "Get-QuotaBlock: does not classify ordinary text that merely says 'premium requests'" ($null -eq (Get-QuotaBlock $copilotOrdinary))

    $multilineQuotaText = "some preamble`nYou've hit your session limit`nfollowed by a long trailing line of unrelated padding text that would be far too long to print verbatim`nmore text"
    $multilineQuota = Get-QuotaBlock $multilineQuotaText
    Test-Result "Get-QuotaBlock: returns a short single-line message rather than the whole input" (
        $multilineQuota -and -not [string]::IsNullOrEmpty($multilineQuota.Message) -and
        $multilineQuota.Message -notmatch "`n" -and $multilineQuota.Message.Length -lt 100
    )
} catch {
    Write-Host "FAIL Get-QuotaBlock -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Get-OwnedPaths / Get-TaskReasoning / Limit-Text
# Get-TaskReasoning reads the supervisor's $DocsReasoning parameter through its definition-site
# scope, which here is this script's top level; set it the same way agent-supervisor.ps1 does.
$DocsReasoning = "low"
try {
    $codeBody = "Provider: claude`n`n## Owned paths`n- ``scripts/test-supervisor.ps1```n- ``docs/AGENT_SUPERVISOR.md```n`n## Acceptance checks`n- x"
    $docsBody = "## Owned paths`n- ``docs/decisions/003-*.md```n- ``docs/architecture/source-of-truth.yaml```n`n## Acceptance checks`n- y"
    Test-Result "Get-OwnedPaths: extracts every bullet under Owned paths and nothing after it" (((Get-OwnedPaths $codeBody) -join "|") -eq "scripts/test-supervisor.ps1|docs/AGENT_SUPERVISOR.md")
    Test-Result "Get-OwnedPaths: returns none when the heading is absent" (@(Get-OwnedPaths "no heading here").Count -eq 0)
    Test-Result "Get-TaskReasoning: a task touching scripts/ stays at medium" ((Get-TaskReasoning $codeBody) -eq "medium")
    Test-Result "Get-TaskReasoning: a documents-only task uses DocsReasoning" ((Get-TaskReasoning $docsBody) -eq "low")
    Test-Result "Get-TaskReasoning: a source directory keeps medium" ((Get-TaskReasoning "## Owned paths`n- ``src/core/jobs/``") -eq "medium")
    Test-Result "Get-TaskReasoning: no owned paths means medium" ((Get-TaskReasoning "") -eq "medium")
    $capped = Limit-Text ("x" * 5000) 3500 "handoff"
    Test-Result "Limit-Text: keeps the head and appends a truncation note" ($capped.StartsWith("xxxx") -and $capped.Length -lt 3800 -and $capped -match "truncated by the supervisor at 3500")
    Test-Result "Limit-Text: leaves short text untouched" ((Limit-Text "short" 3500) -eq "short")
} catch {
    Write-Host "FAIL Get-OwnedPaths / Get-TaskReasoning / Limit-Text -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Get-QuotaBlock: reset time from the matching line only
try {
    $mixed = "the task body quotes ``resets 5:30pm`` as a fixture`nERROR: You've hit your usage limit. Upgrade to Pro or try again at 11:43 PM."
    $mixedQuota = Get-QuotaBlock $mixed
    Test-Result "Get-QuotaBlock: parses the reset time from the matching line, not from earlier text" (
        $mixedQuota -and $mixedQuota.Until -and $mixedQuota.Until.Hour -eq 23 -and $mixedQuota.Until.Minute -eq 43 -and $mixedQuota.Message -match "^You've hit your usage limit"
    )
} catch {
    Write-Host "FAIL Get-QuotaBlock (matching line) -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Get-RecentSessions (sessions.json cache)
# Deliberately at top-level scope, same reason as Load-State/Save-State above: Get-RecentSessions
# reads $logPath and $statePath (never parameters) via its own lexical (definition-site) scope
# chain, which is this script's top-level scope. The stub Get-ClaudeJsonlUsage defined below is
# also a plain top-level function, so PowerShell's scope lookup finds it instead of any real
# definition (which is never extracted into this script) -- it never touches
# ~/.claude/projects, just counts how many times each session's work dir was asked for and
# returns a fixed value, which is exactly what proves the cache skips it for an already-cached
# session and never skips it for a still-running one.
try {
    $tempSessionsDir = Join-Path $env:TEMP "test-supervisor-sessions-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $tempSessionsDir -ErrorAction Stop | Out-Null
    try {
        $statePath = $tempSessionsDir
        $logPath = Join-Path $tempSessionsDir "supervisor.log"
        $sessionsCachePath = Join-Path $tempSessionsDir "sessions.json"

        $script:stubCalls = @{}
        function Get-ClaudeJsonlUsage([string]$WorkDir, [datetime]$From, [datetime]$To) {
            if (-not $script:stubCalls.ContainsKey($WorkDir)) { $script:stubCalls[$WorkDir] = 0 }
            $script:stubCalls[$WorkDir]++
            return @{ total = 5555; cacheRead = 0 }
        }

        $cachedWorkDir = Join-Path $tempSessionsDir "work-cached"
        $uncachedWorkDir = Join-Path $tempSessionsDir "work-uncached"
        $runningWorkDir = Join-Path $tempSessionsDir "work-running"

        $launchedCached = (Get-Date).AddMinutes(-40)
        $finishedCached = (Get-Date).AddMinutes(-35)
        $launchedUncached = (Get-Date).AddMinutes(-30)
        $finishedUncached = (Get-Date).AddMinutes(-25)
        $launchedRunning = (Get-Date).AddMinutes(-10)

        $logLines = @(
            "$($launchedCached.ToString('o')) [cached-tag] launching claude (edit) in $cachedWorkDir, timeout 3600s",
            "$($finishedCached.ToString('o')) [cached-tag] claude finished with exit 0",
            "$($launchedUncached.ToString('o')) [uncached-tag] launching claude (edit) in $uncachedWorkDir, timeout 3600s",
            "$($finishedUncached.ToString('o')) [uncached-tag] claude finished with exit 0",
            "$($launchedRunning.ToString('o')) [running-tag] launching claude (edit) in $runningWorkDir, timeout 3600s"
        )
        [System.IO.File]::WriteAllLines($logPath, $logLines, (New-Object System.Text.UTF8Encoding($false)))

        $seedCache = [ordered]@{
            "cached-tag" = [ordered]@{ provider = "claude"; tokens = 12345; finishedAt = $finishedCached.ToString("o") }
        }
        [System.IO.File]::WriteAllText($sessionsCachePath, ($seedCache | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))

        $since = (Get-Date).AddHours(-1)
        $first = @(Get-RecentSessions $since)
        $firstCached = $first | Where-Object { $_.tag -eq "cached-tag" } | Select-Object -First 1
        $firstUncached = $first | Where-Object { $_.tag -eq "uncached-tag" } | Select-Object -First 1
        $firstRunning = $first | Where-Object { $_.tag -eq "running-tag" } | Select-Object -First 1

        Test-Result "Get-RecentSessions: reuses a cached finished session's tokens without calling the stub" (
            $firstCached -and $firstCached.tokens -eq 12345 -and -not $script:stubCalls.ContainsKey($cachedWorkDir)
        )
        Test-Result "Get-RecentSessions: computes an uncached finished session's tokens via the stub" (
            $firstUncached -and $firstUncached.tokens -eq 5555 -and $script:stubCalls[$uncachedWorkDir] -eq 1
        )
        Test-Result "Get-RecentSessions: computes a still-running session's tokens via the stub" (
            $firstRunning -and $firstRunning.tokens -eq 5555 -and $script:stubCalls[$runningWorkDir] -eq 1
        )

        $cacheAfterFirst = $null
        try { $cacheAfterFirst = Get-Content -Raw -Path $sessionsCachePath -Encoding utf8 | ConvertFrom-Json } catch { }
        $cacheAfterFirstNames = if ($cacheAfterFirst) { @($cacheAfterFirst.PSObject.Properties.Name) } else { @() }
        Test-Result "Get-RecentSessions: persists the newly-computed finished session into sessions.json" (
            $cacheAfterFirstNames -contains $firstUncached.runId -and $cacheAfterFirst.($firstUncached.runId).tokens -eq 5555
        )
        Test-Result "Get-RecentSessions: never persists a still-running session into sessions.json" (
            -not ($cacheAfterFirstNames -contains "running-tag")
        )

        $second = @(Get-RecentSessions $since)
        Test-Result "Get-RecentSessions: a second call reuses the now-cached session without calling the stub again" (
            $script:stubCalls[$uncachedWorkDir] -eq 1
        )
        Test-Result "Get-RecentSessions: a still-running session is recomputed via the stub on every call" (
            $script:stubCalls[$runningWorkDir] -eq 2
        )
        Test-Result "Get-RecentSessions: a cached session is still never sent through the stub on a later call" (
            -not $script:stubCalls.ContainsKey($cachedWorkDir)
        )
    } finally {
        Remove-Item -Recurse -Force $tempSessionsDir -ErrorAction SilentlyContinue
    }
} catch {
    Write-Host "FAIL Get-RecentSessions (sessions.json cache) -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Get-RecentSessions (stale-only cache pruning)
# A prior round only pruned entries that fell out of the 24h window when a NEW entry was computed
# in the same call, so a cycle with no uncached sessions (e.g. every session already cached, or no
# sessions at all) left stale entries in sessions.json forever. This proves pruning runs on every
# call regardless of whether anything new gets cached.
try {
    $tempStaleDir = Join-Path $env:TEMP "test-supervisor-stale-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $tempStaleDir -ErrorAction Stop | Out-Null
    try {
        $statePath = $tempStaleDir
        $logPath = Join-Path $tempStaleDir "supervisor.log"
        $staleCachePath = Join-Path $tempStaleDir "sessions.json"

        # No sessions at all in the log window -- this call has nothing new to cache, so the only
        # way the stale entry disappears is unconditional pruning.
        [System.IO.File]::WriteAllLines($logPath, @(), (New-Object System.Text.UTF8Encoding($false)))

        $staleFinishedAt = (Get-Date).AddHours(-2)
        $seedStaleCache = [ordered]@{
            "stale-tag" = [ordered]@{ provider = "claude"; tokens = 999; finishedAt = $staleFinishedAt.ToString("o") }
        }
        [System.IO.File]::WriteAllText($staleCachePath, ($seedStaleCache | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))

        $staleSince = (Get-Date).AddHours(-1)
        $null = @(Get-RecentSessions $staleSince)

        $cacheAfterPrune = $null
        try { $cacheAfterPrune = Get-Content -Raw -Path $staleCachePath -Encoding utf8 | ConvertFrom-Json } catch { }
        $cacheAfterPruneNames = if ($cacheAfterPrune) { @($cacheAfterPrune.PSObject.Properties.Name) } else { @() }
        Test-Result "Get-RecentSessions: prunes a stale cache entry even when no session is newly cached" (
            -not ($cacheAfterPruneNames -contains "stale-tag")
        )
    } finally {
        Remove-Item -Recurse -Force $tempStaleDir -ErrorAction SilentlyContinue
    }
} catch {
    Write-Host "FAIL Get-RecentSessions (stale-only cache pruning) -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Get-CodexTokensFromLog
# Use synthetic JSONL fixtures and extract the helper independently through the AST. This keeps
# the token computation test independent of session discovery, cache state, and a live Codex run.
try {
    . ([scriptblock]::Create((Get-FunctionSource $supervisorPath "Get-CodexTokensFromLog")))
    $tempCodexTokensDir = Join-Path $env:TEMP "test-supervisor-codex-tokens-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $tempCodexTokensDir -ErrorAction Stop | Out-Null
    try {
        $jsonlPath = Join-Path $tempCodexTokensDir "token-count.jsonl"
        $jsonl = @(
            '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input":120,"cached_input":30,"output":50}}}}',
            '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input":200,"cached_input":40,"output":60}}}}'
        )
        [System.IO.File]::WriteAllLines($jsonlPath, $jsonl, (New-Object System.Text.UTF8Encoding($false)))
        Test-Result "Get-CodexTokensFromLog: uses the last token_count total including cached input" ((Get-CodexTokensFromLog $jsonlPath) -eq 300)

        $legacyPath = Join-Path $tempCodexTokensDir "legacy.log"
        [System.IO.File]::WriteAllText($legacyPath, "some output`r`ntokens used`r`n44.559`r`n", (New-Object System.Text.UTF8Encoding($false)))
        Test-Result "Get-CodexTokensFromLog: preserves the legacy tokens-used fallback" ((Get-CodexTokensFromLog $legacyPath) -eq 44559)

        $emptyPath = Join-Path $tempCodexTokensDir "empty.log"
        [System.IO.File]::WriteAllText($emptyPath, "no token information here`r`n", (New-Object System.Text.UTF8Encoding($false)))
        Test-Result "Get-CodexTokensFromLog: returns null without throwing when neither source exists" ($null -eq (Get-CodexTokensFromLog $emptyPath))
    } finally {
        Remove-Item -Recurse -Force $tempCodexTokensDir -ErrorAction SilentlyContinue
    }
} catch {
    Write-Host "FAIL Get-CodexTokensFromLog -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Test-QueueLabelsStale
# The pure staleness check that throttles the three dashboard-only label queries:
# stale (needs a refetch) when never fetched before, when 5 or more cycles have passed since the
# last fetch, or when 10 or more minutes have passed since the last fetch -- whichever threshold
# is reached first, exactly as documented above the function in agent-supervisor.ps1. $Now is a
# fixed timestamp passed by the caller (never Get-Date read inside the function under test), so
# identical arguments always produce identical results.
try {
    $fixedNow = [datetime]"2026-01-01T00:00:00"
    Test-Result "Test-QueueLabelsStale: never fetched before (LastFetchedAt = `$null) is stale" (
        Test-QueueLabelsStale $null 0 $fixedNow
    )
    Test-Result "Test-QueueLabelsStale: never fetched before (CyclesSinceFetch large) is stale even with a recent-looking date" (
        Test-QueueLabelsStale $fixedNow 999 $fixedNow
    )
    Test-Result "Test-QueueLabelsStale: not stale immediately after a fetch" (
        -not (Test-QueueLabelsStale $fixedNow 0 $fixedNow)
    )
    Test-Result "Test-QueueLabelsStale: not stale just under both thresholds" (
        -not (Test-QueueLabelsStale $fixedNow 4 ($fixedNow.AddMinutes(9)))
    )
    Test-Result "Test-QueueLabelsStale: stale once the cycle-count threshold (5) is reached" (
        Test-QueueLabelsStale $fixedNow 5 $fixedNow
    )
    Test-Result "Test-QueueLabelsStale: stale once the time threshold (10 minutes) is reached" (
        Test-QueueLabelsStale $fixedNow 0 ($fixedNow.AddMinutes(10))
    )
    Test-Result "Test-QueueLabelsStale: identical arguments produce the identical result regardless of wall-clock time (purity)" (
        (Test-QueueLabelsStale $fixedNow 2 ($fixedNow.AddMinutes(3))) -eq (Test-QueueLabelsStale $fixedNow 2 ($fixedNow.AddMinutes(3)))
    )
} catch {
    Write-Host "FAIL Test-QueueLabelsStale -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- required-check verification
# Guards against a silent partial run: a section that throws partway through (e.g. an
# unwritable temp directory) is caught above and reported as a FAIL for that section, but it
# may still have produced zero PASS/FAIL lines for one or more of the helpers it was meant to
# exercise. Cross-check the required helper names against what actually printed a result, and
# fail loudly for anything missing instead of letting a partially-skipped run reach a
# successful summary.
$requiredPrefixes = @("Get-Field", "Get-TaskRole", "Get-AgentCommonSection", "Get-IssueRefs", "Extract-Json", "Load-State", "Save-State", "Fill-Template", "Other-Provider", "Read-Handoff", "Get-QuotaBlock", "Get-OwnedPaths", "Get-TaskReasoning", "Limit-Text", "Get-RecentSessions", "Get-CodexTokensFromLog", "Test-QueueLabelsStale")
foreach ($prefix in $requiredPrefixes) {
    $found = $script:executedNames | Where-Object { $_.StartsWith($prefix) } | Select-Object -First 1
    if (-not $found) {
        Write-Host "FAIL $prefix -- no result was recorded for this helper (its section aborted early; see the FAIL above)"
        $script:failCount++
    }
}

# ----------------------------------------------------------------------------- -DryRun smoke check helpers
# Windows PowerShell 5.1's [System.Diagnostics.Process]::Kill() takes no arguments (the
# bool-argument overload that also ends child processes was added in .NET Core 3.0) and
# only ends the immediate process anyway. taskkill /T walks and ends the whole tree a
# timed-out process may have spawned, and works unmodified on every Windows box.
function Stop-ProcessTree([int]$ProcessId) {
    & taskkill.exe /PID $ProcessId /T /F *> $null
}

# Runs $FilePath with $Arguments (a single, already-quoted argument string) and waits up to
# $TimeoutMilliseconds, returning @{ TimedOut = [bool]; ExitCode = [int or $null] }.
#
# Built directly on System.Diagnostics.Process rather than Start-Process -PassThru: a
# Windows PowerShell 5.1 reproduction showed Start-Process's -PassThru object can report a
# null ExitCode for a redirected child even after WaitForExit() returns $true. Starting and
# owning the Process object ourselves, and reading ExitCode from that same live object right
# after WaitForExit(), avoids that gap. Standard output/error are redirected and drained
# asynchronously (BeginOutputReadLine/BeginErrorReadLine); Process's DataReceived events are
# no-ops with no subscriber, so this safely discards the output while still preventing the
# child from blocking on a full pipe buffer -- only the exit code is needed here.
#
# A process that fails to start at all (missing executable, permissions) throws from
# $proc.Start() itself; that is deliberately left uncaught here and handled by the caller's
# try/catch, so a startup failure is reported as FAIL rather than treated the same as a clean
# exit or silently producing no result.
function Invoke-TimedProcess([string]$FilePath, [string]$Arguments, [string]$WorkingDirectory, [int]$TimeoutMilliseconds) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()
        if ($proc.WaitForExit($TimeoutMilliseconds)) {
            return @{ TimedOut = $false; ExitCode = $proc.ExitCode }
        } else {
            Stop-ProcessTree $proc.Id
            try { $proc.WaitForExit(5000) | Out-Null } catch { }
            return @{ TimedOut = $true; ExitCode = $null }
        }
    } finally {
        $proc.Dispose()
    }
}

# ----------------------------------------------------------------------------- -DryRun smoke check
if ($DryRun) {
    try {
        $ghCommand = @(Get-Command "gh.exe", "gh.cmd", "gh" -ErrorAction SilentlyContinue) | Select-Object -First 1
        if (-not $ghCommand) {
            Write-Host "SKIP DryRun smoke check: the GitHub CLI is not installed / not on PATH (agent-supervisor.ps1 requires it even in -DryRun mode)"
        } else {
            # Shared time budget so the whole smoke check stays comfortably under a minute even
            # in the worst case: up to 10s to check gh auth, then whatever is left of a 45s
            # combined budget for the supervisor dry run itself (capped at 35s), plus a shared
            # allowance of up to 5s for a taskkill + WaitForExit if either step times out.
            $dryRunStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $authResult = Invoke-TimedProcess $ghCommand.Source "auth status" $null 10000

            if ($authResult.TimedOut) {
                Write-Host "SKIP DryRun smoke check: 'gh auth status' did not respond within 10s"
            } elseif ($authResult.ExitCode -ne 0) {
                Write-Host "SKIP DryRun smoke check: the GitHub CLI is installed but not authenticated (agent-supervisor.ps1 requires 'gh auth login' even in -DryRun mode)"
            } else {
                $supervisorScript = Join-Path $PSScriptRoot "agent-supervisor.ps1"
                # agent-supervisor.ps1 resolves docs\agent-prompts, and (by default) its state
                # directory, relative to its *working directory* ($root = (Get-Location).Path), not
                # relative to the script's own location. Rather than redirect -StateDirectory into
                # %TEMP% -- which breaks when %TEMP% and the repo are on different drives, since a
                # relative Windows path cannot cross drives and Join-Path does not special-case an
                # absolute second argument -- run the supervisor with its working directory set to a
                # throwaway %TEMP% root that contains only the one directory it checks for at
                # startup (Test-Path $promptDir). Its default ".agent-state" then lands inside that
                # same throwaway root, fully isolated, on whatever drive %TEMP% is on -- no
                # cross-drive path math needed at all. The real repo, and its real .agent-state/,
                # are never touched.
                $dryRunRoot = Join-Path $env:TEMP "test-supervisor-dryrun-root-$([Guid]::NewGuid().ToString('N'))"
                New-Item -ItemType Directory -Force -Path (Join-Path $dryRunRoot "docs\agent-prompts") -ErrorAction Stop | Out-Null
                try {
                    $remainingMs = 45000 - $dryRunStopwatch.ElapsedMilliseconds
                    $supervisorTimeoutMs = [Math]::Max(5000, [Math]::Min(35000, $remainingMs))
                    # Any repository the authenticated account can read works; a dry run only lists issues.
                    $dryRunRepo = if ($env:AGENT_TEST_REPOSITORY) { $env:AGENT_TEST_REPOSITORY } else { "octocat/Hello-World" }
                    $dryRunArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Repository {1} -DryRun -Once' -f $supervisorScript, $dryRunRepo
                    $result = Invoke-TimedProcess "powershell.exe" $dryRunArgs $dryRunRoot $supervisorTimeoutMs
                    if ($result.TimedOut) {
                        Write-Host "FAIL DryRun smoke check -- agent-supervisor.ps1 -DryRun -Once did not exit within $([int]($supervisorTimeoutMs / 1000))s"
                        $script:failCount++
                    } elseif ($result.ExitCode -ne 0) {
                        Write-Host "FAIL DryRun smoke check -- agent-supervisor.ps1 -DryRun -Once exited with code $($result.ExitCode)"
                        $script:failCount++
                    } else {
                        Write-Host "PASS DryRun smoke check: agent-supervisor.ps1 -DryRun -Once started and exited cleanly"
                    }
                } finally {
                    Remove-Item -Recurse -Force $dryRunRoot -ErrorAction SilentlyContinue
                }
            }
        }
    } catch {
        Write-Host "FAIL DryRun smoke check -- unexpected error: $($_.Exception.Message)"
        $script:failCount++
    }
}

# ----------------------------------------------------------------------------- acceptance wrapper: nested -Command really runs once unwrapped
# A nested-command acceptance line of the kind planners write, run through the same wrapper shape as
# Invoke-AcceptanceCommands (-EncodedCommand of `& { <line> }`): as written it can only fail;
# unwrapped, the parser check it was meant to be really executes and passes on this very file.
try {
    $issue72 = 'powershell -NoProfile -Command "$errs=$null; [System.Management.Automation.Language.Parser]::ParseFile(''scripts/test-supervisor.ps1'',[ref]$null,[ref]$errs)|Out-Null; if($errs.Count -gt 0){$errs|ForEach-Object{Write-Host $_.Message}; exit 1}; exit 0"'
    $repoRoot = Split-Path -Parent $PSScriptRoot
    function Invoke-LikeSupervisor([string]$Line) {
        $wrapped = "`$ErrorActionPreference = 'Stop'; `$ok = `$true; try { & { $Line }; `$ok = `$? } catch { `$_ | Out-String | Write-Output; `$ok = `$false }; if (`$LASTEXITCODE) { exit `$LASTEXITCODE } elseif (-not `$ok) { exit 1 } else { exit 0 }"
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($wrapped))
        return (Invoke-TimedProcess "powershell.exe" "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded" $repoRoot 60000)
    }
    $asWritten = Invoke-LikeSupervisor $issue72
    Test-Result "acceptance wrapper: the nested line as the planner wrote it fails (exit != 0)" (-not $asWritten.TimedOut -and $asWritten.ExitCode -ne 0)
    $unwrapped = Invoke-LikeSupervisor (Resolve-AcceptanceCommand $issue72).Command
    Test-Result "acceptance wrapper: the same check unwrapped really runs and passes (exit 0)" (-not $unwrapped.TimedOut -and $unwrapped.ExitCode -eq 0)
    $brokenFile = Join-Path $env:TEMP ("test-supervisor-broken-" + [guid]::NewGuid() + ".ps1")
    Set-Content -LiteralPath $brokenFile -Value 'if ( { ' -Encoding ASCII
    $issue72Broken = $issue72.Replace("scripts/test-supervisor.ps1", $brokenFile.Replace('\', '/'))
    $detects = Invoke-LikeSupervisor (Resolve-AcceptanceCommand $issue72Broken).Command
    Remove-Item -LiteralPath $brokenFile -Force -ErrorAction SilentlyContinue
    Test-Result "acceptance wrapper: the unwrapped check still fails on a file that does not parse (it is a real check, not a pass-through)" (-not $detects.TimedOut -and $detects.ExitCode -eq 1)
} catch {
    Write-Host "FAIL acceptance wrapper -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- orphan chains and leaked log-file holders
# The relaunch block this guards against: an agent's `sh -c "<tool> --headless ... | tail"` outlived
# the agent, and its inherited copies of the wrapper's log handles kept task-stdout.txt locked.
# The tool names come from orphanSweep.processNames; "enginetool" stands in for one here.
$script:OrphanProcessNames = @('enginetool')
try {
    $base = Get-Date
    $t = @{}
    $t[50]  = @{ Parent = 4;   Name = 'svchost.exe';                           Started = $base }
    $t[100] = @{ Parent = 50;  Name = 'cmd.exe';                               Started = $base.AddSeconds(1) }
    $t[200] = @{ Parent = 100; Name = 'powershell.exe';                        Started = $base.AddSeconds(2) }
    $t[300] = @{ Parent = 200; Name = 'node.exe';                              Started = $base.AddSeconds(3) }
    $t[400] = @{ Parent = 300; Name = 'sh.exe';                                Started = $base.AddSeconds(4) }
    $t[500] = @{ Parent = 400; Name = 'EngineTool_v2_console.exe';             Started = $base.AddSeconds(5) }
    $t[600] = @{ Parent = 500; Name = 'EngineTool_v2.exe';                     Started = $base.AddSeconds(5) }
    Test-Result "Test-OrphanChain: a tool whose whole launcher chain is alive is not orphaned" (-not (Test-OrphanChain 600 $t))
    $agentGone = $t.Clone(); $agentGone.Remove(300)
    Test-Result "Test-OrphanChain: a tool under a surviving sh whose agent is gone is orphaned" (Test-OrphanChain 600 $agentGone)
    Test-Result "Test-OrphanChain: without the tool configured as a launcher link, its console wrapper stops the climb" (-not (Test-OrphanChain 600 $agentGone @()))
    $parentGone = $t.Clone(); $parentGone.Remove(500)
    Test-Result "Test-OrphanChain: a tool whose direct parent is gone is orphaned" (Test-OrphanChain 600 $parentGone)
    $recycled = $t.Clone(); $recycled[300] = @{ Parent = 200; Name = 'node.exe'; Started = $base.AddMinutes(30) }
    Test-Result "Test-OrphanChain: a 'parent' younger than its child is a recycled PID, so the chain counts as broken" (Test-OrphanChain 600 $recycled)
    $u = @{}
    $u[10] = @{ Parent = 1;  Name = 'explorer.exe';                          Started = $base }
    $u[20] = @{ Parent = 10; Name = 'WindowsTerminal.exe';                   Started = $base.AddSeconds(1) }
    $u[30] = @{ Parent = 20; Name = 'powershell.exe';                        Started = $base.AddSeconds(2) }
    $u[40] = @{ Parent = 30; Name = 'EngineTool_v2_console.exe';             Started = $base.AddSeconds(3) }
    $u[50] = @{ Parent = 40; Name = 'EngineTool_v2.exe';                     Started = $base.AddSeconds(3) }
    Test-Result "Test-OrphanChain: the owner's own copy under a terminal is never orphaned, even though explorer's own parent is gone" (-not (Test-OrphanChain 50 $u))
    Test-Result "Test-OrphanCandidate: a configured name with the command-line filter matches" (Test-OrphanCandidate 'EngineTool_v2.exe' 'EngineTool_v2.exe --headless --script t' @('enginetool') '--headless')
    Test-Result "Test-OrphanCandidate: an interactive copy without the filter text is left alone" (-not (Test-OrphanCandidate 'EngineTool_v2.exe' 'EngineTool_v2.exe --editor' @('enginetool') '--headless'))
    Test-Result "Test-OrphanCandidate: an unconfigured name is never a candidate" (-not (Test-OrphanCandidate 'node.exe' 'node server.js --headless' @('enginetool') '--headless'))
    Test-Result "Test-OrphanCandidate: nothing is a candidate when no names are configured" (-not (Test-OrphanCandidate 'EngineTool_v2.exe' 'x --headless' @() ''))

    $holders = @(
        [pscustomobject]@{ Pid = 1; App = 'cmd' }, [pscustomobject]@{ Pid = 2; App = 'powershell' },
        [pscustomobject]@{ Pid = 3; App = 'sh' }, [pscustomobject]@{ Pid = 4; App = 'Engine Tool' })
    $leaked = @(Select-LeakedHolders $holders 2 @(1))
    Test-Result "Select-LeakedHolders: keeps self and its ancestors, returns every other holder" (($leaked.Count -eq 2) -and ((($leaked | ForEach-Object { $_.Pid }) -join ',') -eq '3,4'))
    Test-Result "Select-LeakedHolders: nothing to kill when only self and ancestors hold the file" (@(Select-LeakedHolders @($holders[0], $holders[1]) 2 @(1)).Count -eq 0)
    Test-Result "Select-LeakedHolders: an empty holder list yields nothing" (@(Select-LeakedHolders @() 2 @(1)).Count -eq 0)

    # Real handles, not a mock: a child process that holds a temp file open must come back from
    # the Restart Manager by PID, and a file nobody holds must come back empty.
    $lockFile = Join-Path $env:TEMP ("test-supervisor-lock-" + [guid]::NewGuid() + ".txt")
    Set-Content -LiteralPath $lockFile -Value "x" -Encoding ASCII
    $holderCmd = "`$f = [System.IO.File]::Open('$lockFile', 'Open', 'ReadWrite', 'None'); Start-Sleep -Seconds 60"
    $holderProc = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $holderCmd) -PassThru -WindowStyle Hidden
    try {
        $found = $false
        for ($i = 0; $i -lt 40 -and -not $found; $i++) {
            Start-Sleep -Milliseconds 500
            $found = (@(Get-FileHolders @($lockFile) | Where-Object { $_.Pid -eq $holderProc.Id }).Count -eq 1)
        }
        Test-Result "Get-FileHolders: reports the process that holds a file open (Restart Manager)" $found
        $reported = @(Get-FileHolders @($lockFile) | Where-Object { $_.Pid -eq $holderProc.Id })
        $startOk = $false
        if ($reported.Count -eq 1 -and $reported[0].StartedUtc) { $startOk = ([Math]::Abs(($holderProc.StartTime.ToUniversalTime() - $reported[0].StartedUtc).TotalSeconds) -le 2) }
        Test-Result "Get-FileHolders: the reported start time matches the process (the PID-reuse guard has something to compare)" $startOk
        $unheld = Join-Path $env:TEMP ("test-supervisor-unheld-" + [guid]::NewGuid() + ".txt")
        Set-Content -LiteralPath $unheld -Value "x" -Encoding ASCII
        Test-Result "Get-FileHolders: a file nobody holds open has no holders" (@(Get-FileHolders @($unheld)).Count -eq 0)
        Remove-Item -LiteralPath $unheld -Force -ErrorAction SilentlyContinue
        Test-Result "Get-FileHolders: a path that does not exist has no holders" (@(Get-FileHolders @("$unheld.missing")).Count -eq 0)
    } finally {
        Stop-Process -Id $holderProc.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 300
        Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
    }
} catch {
    Write-Host "FAIL orphan chains / leaked holders -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- summary
Write-Host ""
if ($script:failCount -gt 0) {
    Write-Host "SUMMARY: $script:failCount check(s) FAILED"
    exit 1
} else {
    Write-Host "SUMMARY: all checks passed"
    exit 0
}
