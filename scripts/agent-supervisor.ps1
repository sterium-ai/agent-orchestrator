<#
.SYNOPSIS
Unattended orchestrator: objective -> plan -> implement -> independent review -> merge.

.DESCRIPTION
GitHub issues are the durable queue and the audit trail. The product owner files an issue
labelled `objective`; everything after that is automatic:

  objective            planner agent splits it into task issues (agent-ready / agent-blocked)
  agent-ready          implementer agent works in an isolated worktree; supervisor validates,
                       pushes, opens a draft PR                    -> agent-review
  agent-review         a DIFFERENT provider reviews read-only (claude, codex or copilot; whoever
                       is assigned, or the first other one with quota left)
                         approve          -> squash-merge, close, unblock dependants -> agent-done
                         request_changes  -> author revises (up to -MaxRevisions)   -> agent-review
  agent-failed         anything the supervisor could not resolve; reported on the objective

Run from the main clone of the TARGET repository (a checkout of `main`), for example:

  powershell -NoProfile -ExecutionPolicy Bypass -File <tool>\scripts\agent-supervisor.ps1 `
      -ConfigPath .\agent-orchestrator.json -DryRun -Once

Settings come from a JSON configuration file (-ConfigPath, or agent-orchestrator.json in the
current directory when present; see agent-orchestrator.example.json) and can be overridden
with the parameters below. A repository is required: there is no default.

Worktrees live next to the clone (../<clone>-agent-worktrees/ unless configured). State that
must survive restarts lives in GitHub (labels, comments, PRs); per-issue counters live in the
state directory (.agent-state/ by default).
#>
[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$DryRun,
    # JSON configuration file. Defaults to agent-orchestrator.json in the current directory when
    # it exists. Parameters passed on the command line override the file.
    [string]$ConfigPath = "",
    [int]$PollSeconds = 120,
    # owner/name of the GitHub repository whose issues drive the pipeline. Required.
    [string]$Repository = "",
    [string]$StateDirectory = ".agent-state",
    # Prompt templates. Default: docs/agent-prompts in the target repository when it has an
    # implementer.md there, otherwise the templates shipped with this tool.
    [string]$PromptsDirectory = "",
    # Where task worktrees are created. Default: ../<clone folder>-agent-worktrees.
    [string]$WorktreeRoot = "",
    [ValidateSet("claude", "codex", "copilot")][string]$PlannerProvider = "claude",
    # Model for GitHub Copilot CLI sessions. "auto" lets Copilot route per request (it picks
    # cheap flash models for small jobs) and does not accept a reasoning-effort setting.
    [string]$CopilotModel = "auto",
    # Models for the one bounded expert-recovery session per task (see
    # docs/decisions/003-bounded-expert-recovery.md). Empty means the CLI's default model.
    [string]$ClaudeExpertModel = "claude-fable-5-1",
    [string]$CodexExpertModel = "gpt-6-astra",
    # Reserve Codex logins. Every subfolder here that holds an auth.json is a separate CODEX_HOME
    # the owner has logged in with `$env:CODEX_HOME=<folder>; codex login`; the default ~/.codex
    # is always the first account. When one login hits its usage limit the next one takes the
    # very same task on the next cycle instead of waiting for the reset (see Get-ProviderAccounts).
    [string]$CodexAccountsDir = (Join-Path $env:USERPROFILE ".codex-accounts"),
    # The only stopping rule for a task the reviewer keeps rejecting. Generous, because the
    # cheaper fix for slow convergence is a reviewer that reports every instance of a problem at
    # once (see docs/agent-prompts/reviewer.md) rather than a cleverer ceiling.
    [int]$MaxRevisions = 6,
    # How many times the repair step (Invoke-Repair) may change a task -- its text, its owned
    # paths, or the author's instructions -- before a person is asked. Each repair resets the
    # round counters, subject also to MaxTotalRevisions across attempts.
    # A `rescope` (widening owned paths) does not spend a repair, but corrections still count.
    [int]$MaxRepairs = 2,
    # Cumulative correction attempts; repairs never reset this ceiling.
    [ValidateRange(1, 100)][int]$MaxTotalRevisions = 12,
    [bool]$ExpertRecoveryEnabled = $true,
    [ValidateRange(1, 90)][int]$ExpertTimeoutMinutes = 45,
    # How long a provider must be unavailable before a queued task is handed to the other one.
    [int]$SwapAfterMinutes = 30,
    [int]$PlannerTimeoutMinutes = 25,
    [int]$ImplementTimeoutMinutes = 90,
    [int]$ReviewTimeoutMinutes = 30,
    # The project's own test command, run by the supervisor on the host in the task worktree
    # before every review (the "test gate"). Empty disables the gate. Runs in a fresh
    # `powershell -NoProfile`, e.g. "npm test" or "python -m pytest -q".
    [string]$TestCommand = "",
    # Wall-clock bound for the test gate; the whole process tree is killed on timeout.
    [int]$TestGateTimeoutSeconds = 600,
    # Regex over changed repo-relative paths: the gate runs only when one matches. Empty = always.
    [string]$TestGateWhenChanged = "",
    # Optional command run in the worktree before each push (code generators, lockfile updates);
    # files it creates or changes are committed on the author's behalf.
    [string]$PrePushCommand = "",
    # Wall-clock bound for each acceptance command taken from an issue body.
    [int]$AcceptanceTimeoutSeconds = 300,
    # GitHub logins whose issues may define acceptance commands (and whose objectives are
    # planned). Empty = everyone who can label issues (not recommended for public repositories).
    [string[]]$TrustedAuthors = @(),
    # Codex reasoning effort for tasks whose owned paths are all documents (see Get-TaskReasoning).
    # Code tasks always run at "medium". Set to "medium" to switch the experiment off.
    [ValidateSet("low", "medium", "high")][string]$DocsReasoning = "low",
    # How much of the author's handoff is pasted into the reviewer prompt. The full handoff is
    # always in the pull request body; the prompt is charged per round.
    [int]$ReviewerHandoffChars = 3500,
    # Size cap for the "what changed since your last review" diff in follow-up rounds.
    [int]$IncrementalDiffChars = 12000
)

# "Continue": in Windows PowerShell 5.1, native stderr under "Stop" becomes a terminating error.
$ErrorActionPreference = "Continue"
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
$env:GIT_TERMINAL_PROMPT = "0"
# git and gh emit UTF-8; without this, non-ASCII characters in paths (accented letters) are decoded wrongly.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$root = (Get-Location).Path
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$toolRoot = Split-Path -Parent $scriptDir
$runner = Join-Path $scriptDir "run-agent.ps1"

# ----------------------------------------------------------------------------- configuration
# Reads a dotted path ("testGate.command") out of the parsed configuration; $null when absent.
function Get-ConfigValue($Config, [string]$Path) {
    $node = $Config
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $node) { return $null }
        if ($node -is [hashtable]) { if ($node.ContainsKey($part)) { $node = $node[$part] } else { return $null } }
        elseif ($node.PSObject.Properties[$part]) { $node = $node.$part }
        else { return $null }
    }
    return $node
}

$script:Config = $null
$configFile = if ($ConfigPath) { $ConfigPath } elseif (Test-Path -LiteralPath (Join-Path $root "agent-orchestrator.json")) { Join-Path $root "agent-orchestrator.json" } else { "" }
if ($configFile) {
    if (-not (Test-Path -LiteralPath $configFile)) { throw "Configuration file not found: $configFile" }
    try { $script:Config = Get-Content -Raw -LiteralPath $configFile -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Configuration file $configFile is not valid JSON: $($_.Exception.Message)" }
}
# Parameter -> configuration key. A parameter given on the command line always wins.
$configMap = [ordered]@{
    Repository = 'repository'; StateDirectory = 'stateDirectory'; PromptsDirectory = 'promptsDirectory'
    WorktreeRoot = 'worktreeRoot'; PollSeconds = 'pollSeconds'; PlannerProvider = 'plannerProvider'
    CopilotModel = 'models.copilot'; ClaudeExpertModel = 'models.claudeExpert'; CodexExpertModel = 'models.codexExpert'
    CodexAccountsDir = 'codexAccountsDir'; MaxRevisions = 'limits.maxRevisions'; MaxRepairs = 'limits.maxRepairs'
    MaxTotalRevisions = 'limits.maxTotalRevisions'; SwapAfterMinutes = 'limits.swapAfterMinutes'
    ExpertRecoveryEnabled = 'expertRecovery.enabled'; ExpertTimeoutMinutes = 'expertRecovery.timeoutMinutes'
    PlannerTimeoutMinutes = 'timeouts.plannerMinutes'; ImplementTimeoutMinutes = 'timeouts.implementMinutes'
    ReviewTimeoutMinutes = 'timeouts.reviewMinutes'; DocsReasoning = 'docsReasoning'
    TestCommand = 'testGate.command'; TestGateTimeoutSeconds = 'testGate.timeoutSeconds'; TestGateWhenChanged = 'testGate.whenChanged'
    PrePushCommand = 'prePushCommand'; AcceptanceTimeoutSeconds = 'acceptance.timeoutSeconds'; TrustedAuthors = 'acceptance.trustedAuthors'
}
foreach ($name in $configMap.Keys) {
    if ($PSBoundParameters.ContainsKey($name)) { continue }
    $value = Get-ConfigValue $script:Config $configMap[$name]
    if ($null -ne $value) { Set-Variable -Name $name -Value $value }
}
$TrustedAuthors = @($TrustedAuthors | ForEach-Object { ([string]$_).Trim().TrimStart('@') } | Where-Object { $_ })
if ([string]::IsNullOrWhiteSpace($Repository)) {
    throw "No repository configured. Pass -Repository <owner>/<name> or set `"repository`" in the configuration file (see agent-orchestrator.example.json)."
}
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "Repository must look like <owner>/<name>; got '$Repository'." }

# Agent sandbox options handed to run-agent.ps1 (semicolon-separated lists).
$script:AgentShellCommands = (@(Get-ConfigValue $script:Config 'agents.shellCommands') | Where-Object { $_ }) -join ';'
if (-not $script:AgentShellCommands) { $script:AgentShellCommands = 'python;py;powershell' }
$script:AgentExtraDirs = (@(Get-ConfigValue $script:Config 'agents.extraDirectories') | Where-Object { $_ }) -join ';'
$script:AgentSandboxWritableDirs = (@(Get-ConfigValue $script:Config 'agents.sandboxWritableDirectories') | Where-Object { $_ }) -join ';'
# Paths left out of every agent worktree (sparse checkout), e.g. large vendored material.
$script:WorktreeExcludePaths = @(@(Get-ConfigValue $script:Config 'worktree.excludePaths') | Where-Object { $_ } | ForEach-Object { ([string]$_ -replace '\\', '/').Trim('/') })
# Processes an agent or the test gate may leave running after its launcher died (for example a
# headless game engine or a dev server). Only these names are ever swept; see Stop-OrphanedProcesses.
$script:OrphanProcessNames = @(@(Get-ConfigValue $script:Config 'orphanSweep.processNames') | Where-Object { $_ } | ForEach-Object { [string]$_ })
$script:OrphanCommandLineContains = [string](Get-ConfigValue $script:Config 'orphanSweep.commandLineContains')

function Resolve-RootPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return [System.IO.Path]::GetFullPath((Join-Path $root $Path))
}
$promptDir = if ($PromptsDirectory) { Resolve-RootPath $PromptsDirectory }
    elseif (Test-Path -LiteralPath (Join-Path $root "docs\agent-prompts\implementer.md")) { Join-Path $root "docs\agent-prompts" }
    else { Join-Path $toolRoot "docs\agent-prompts" }
# The lessons file lives in the target repository, because learned lessons are committed to its
# main branch. Until the first lesson is learned there, the seed lessons shipped with the tool
# are read instead.
$lessonsRel = [string](Get-ConfigValue $script:Config 'lessonsFile')
if (-not $lessonsRel) { $lessonsRel = 'docs/agent-prompts/lessons.md' }
$lessonsRel = ($lessonsRel -replace '\\', '/').TrimStart('/')
$lessonsFilePath = Join-Path $root ($lessonsRel -replace '/', '\')
$lessonsSeedPath = Join-Path $toolRoot "docs\agent-prompts\lessons.md"
function Get-LessonsReadPath {
    if (Test-Path -LiteralPath $lessonsFilePath) { return $lessonsFilePath }
    if (Test-Path -LiteralPath (Join-Path $promptDir "lessons.md")) { return (Join-Path $promptDir "lessons.md") }
    if (Test-Path -LiteralPath $lessonsSeedPath) { return $lessonsSeedPath }
    return $null
}
# Pure helpers only (Read-Lessons/Build-LessonsSection/etc.); no side effects at dot-source time.
. (Join-Path $scriptDir "lessons.ps1")
# Pure helpers only (Get-TaskRole/Get-AgentCommonSection); no side effects at dot-source time.
. (Join-Path $scriptDir "lib\role-select.ps1")
. (Join-Path $scriptDir "lib\revision-flow.ps1")
. (Join-Path $scriptDir "lib\workflow-policy.ps1")
. (Join-Path $scriptDir "lib\expert-recovery.ps1")
# Pure helpers only (Get-AutoAddedOwnedPaths/Format-OwnedPathsSection); no side effects at
# dot-source time.
. (Join-Path $scriptDir "lib\owned-paths-auto.ps1")
# Pure helpers only (Get-TaskPreflightAdditions/Add-OwnedPathsToBody): the same widening for
# hand-written tasks, applied by Invoke-Implementation before the author reads the body.
. (Join-Path $scriptDir "lib\task-preflight.ps1")
# Pure helper (Test-AcceptanceAuthority): who may define commands the host executes.
. (Join-Path $scriptDir "lib\trusted-authors.ps1")
$script:OwnershipRules = New-OwnershipRules (Get-ConfigValue $script:Config 'ownership')
$statePath = Resolve-RootPath $StateDirectory
$worktreeRoot = if ($WorktreeRoot) { Resolve-RootPath $WorktreeRoot } else { Join-Path (Split-Path $root -Parent) ((Split-Path $root -Leaf) + "-agent-worktrees") }
$lockPath = Join-Path $statePath "supervisor.lock"
$logPath = Join-Path $statePath "supervisor.log"
# A dry run must never interleave with, or contend for, the running supervisor's own log.
if ($DryRun) { $logPath = Join-Path $statePath "supervisor-dryrun.log" }

$L = @{
    Objective = "objective"; ObjectivePlanned = "objective-planned"; ObjectiveDone = "objective-done"; ObjectiveFailed = "objective-failed"
    Blocked = "agent-blocked"; Ready = "agent-ready"; InProgress = "agent-in-progress"; Review = "agent-review"; Done = "agent-done"; Failed = "agent-failed"
}

# ----------------------------------------------------------------------------- utilities

function Write-Log([string]$Message) {
    New-Item -ItemType Directory -Force -Path $statePath | Out-Null
    $line = "$(Get-Date -Format o) $Message"
    # Another process holding a read handle on the log (a tail, an editor, a file viewer) makes
    # Add-Content fail non-terminally, which silently dropped every log line for as long as that
    # handle lived. Retry briefly, and never let logging itself stop the supervisor: the wrapper
    # also captures Write-Host output to task-stdout.txt, so nothing is actually lost.
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try { Add-Content -Path $logPath -Value $line -ErrorAction Stop; break }
        catch { Start-Sleep -Milliseconds 150 }
    }
    # Write-Host, not Write-Output: functions that log must not leak log lines into their return value.
    Write-Host $line
}

function Write-Utf8File([string]$Path, [string]$Content) {
    # UTF-8 without BOM: gh would otherwise send the BOM as part of the issue body,
    # which breaks "Provider:" detection on the first line.
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# ----------------------------------------------------------------------------- provider health
# A provider being out of allowance is a property of the account and the clock, not of any task.
# It is recorded once, centrally, so that every task simply stops asking that provider until the
# stated reset time instead of each one discovering the same wall separately and burning its own
# failure budget against it.
$providersPath = Join-Path $statePath "providers.json"
$statusPath = Join-Path $statePath "status.json"

function Get-ProviderState {
    if (-not (Test-Path $providersPath)) { return @{} }
    try {
        $raw = Get-Content -Raw -Path $providersPath -Encoding utf8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $obj = $raw | ConvertFrom-Json
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    } catch { return @{} }
}

# Raw lookup of one cooldown record. The key is an account key (see Get-ProviderAccounts): the
# bare provider name for its primary login, "codex/<folder>" for a reserve Codex login.
function Get-AccountCooldown([string]$Key) {
    $h = Get-ProviderState
    if (-not $h.ContainsKey($Key)) { return $null }
    $until = $null
    try { $until = [datetime]::Parse([string]$h[$Key].cooldownUntil, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { return $null }
    if ($until -le (Get-Date)) { return $null }
    return $until
}

# A provider may have several logins ("accounts"). A usage limit is a property of the login, so
# cooldowns are recorded per account key: the primary login keeps the bare provider name (an
# unchanged providers.json on a host with one login); a Codex reserve login is "codex/<folder>",
# one per subfolder of $CodexAccountsDir that holds an auth.json, i.e. that the owner has
# logged in with `$env:CODEX_HOME=<folder>; codex login`. The order is the order of use: primary
# first, reserves alphabetically, so a reserve is only touched once every account before it has
# hit its wall. Two logins of one vendor are still ONE provider for review purposes: a Codex
# reserve never reviews Codex's work.
function Get-ProviderAccounts([string]$Provider) {
    $accounts = @([pscustomobject]@{ key = $Provider; label = "primary"; codexHome = $null })
    if ($Provider -eq "codex" -and $CodexAccountsDir -and (Test-Path $CodexAccountsDir)) {
        foreach ($d in @(Get-ChildItem -Path $CodexAccountsDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            if (Test-Path (Join-Path $d.FullName "auth.json")) {
                $accounts += [pscustomobject]@{ key = "codex/$($d.Name)"; label = $d.Name; codexHome = $d.FullName }
            }
        }
    }
    return $accounts
}

# The first login of $Provider that is not resting on a cooldown, or $null when every one is out.
function Get-ReadyAccount([string]$Provider) {
    foreach ($a in @(Get-ProviderAccounts $Provider)) { if ($null -eq (Get-AccountCooldown $a.key)) { return $a } }
    return $null
}

# A provider rests only while ALL of its logins do, and then until the earliest reset among them:
# that is when work can resume with some login.
function Get-ProviderCooldown([string]$Provider) {
    $earliest = $null
    foreach ($a in @(Get-ProviderAccounts $Provider)) {
        $u = Get-AccountCooldown $a.key
        if ($null -eq $u) { return $null }
        if ($null -eq $earliest -or $u -lt $earliest) { $earliest = $u }
    }
    return $earliest
}

function Test-ProviderReady([string]$Provider) { return ($null -eq (Get-ProviderCooldown $Provider)) }

function Sync-QuotaCooldowns {
    if (-not (Test-ProviderReady "copilot")) { return }
    $q = $null
    try { $q = Get-CopilotQuota } catch { return }
    if (-not $q -or -not $q.quotas) { return }
    $cachePath = Join-Path $statePath "copilot-quota-cache.json"
    $fresh = $false
    try {
        $c = Get-Content -Raw -Path $cachePath -Encoding utf8 | ConvertFrom-Json
        $fetchedAt = [datetime]::MinValue
        if ([datetime]::TryParse([string]$c.fetchedAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$fetchedAt)) { $fresh = (((Get-Date) - $fetchedAt).TotalMinutes -lt 30) }
    } catch { }
    if (-not $fresh) { return }
    foreach ($entry in @($q.quotas)) {
        if ("$($entry.label)" -ne "Chat") { continue }
        $used = 0.0
        try { $used = [double]$entry.usedPercent } catch { continue }
        if ($used -lt 100) { continue }
        $until = $null
        try { $until = [datetime]::Parse([string]$entry.resetsAt) } catch { $until = (Get-Date).AddHours(24) }
        if ($until -le (Get-Date)) { continue }
        Set-ProviderCooldown "copilot" $until.AddMinutes(5) "monthly premium requests exhausted ($([math]::Round($used))% used); resets $($until.ToString('yyyy-MM-dd HH:mm'))"
        Write-Log "copilot: monthly premium requests exhausted according to its quota API; resting until $($until.ToString('yyyy-MM-dd HH:mm')) instead of returning empty reviews"
        return
    }
}

function Set-ProviderCooldown([string]$Provider, [datetime]$Until, [string]$Reason) {
    $h = Get-ProviderState
    $h[$Provider] = [pscustomobject]@{
        cooldownUntil = $Until.ToString("o")
        reason        = $Reason
        recordedAt    = (Get-Date).ToString("o")
    }
    try {
        [pscustomobject]$h | ConvertTo-Json -Depth 5 | Set-Content -Path $providersPath -Encoding utf8 -ErrorAction Stop
    } catch {
        Write-Log "Could not record the cooldown for ${Provider}: $($_.Exception.Message)"
    }
}

# The three agent CLIs the supervisor can drive. claude and codex are the planner's usual
# pair; copilot (GitHub Copilot CLI) is the third seat, taken automatically whenever the
# provider a task needs is out of quota, so one exhausted allowance no longer stalls every
# review or implementation for days. A task may also name it explicitly.
$script:AllProviders = @("claude", "codex", "copilot")

function Normalize-Provider([string]$Raw) {
    $v = ([string]$Raw).Trim().ToLowerInvariant()
    if ($script:AllProviders -contains $v) { return $v }
    return "claude"
}

# A provider is usable when it is installed and not resting on a quota cooldown. Only copilot is
# optional on a machine; the other two are checked at startup.
function Test-ProviderUsable([string]$Provider) {
    if (-not (Test-ProviderReady $Provider)) { return $false }
    return [bool](Require-Command $Provider)
}

# The other providers, in the order they should be tried as a stand-in for $Provider: the
# original claude<->codex pairing first, copilot last (it is the newest seat here), and for a
# copilot-authored task claude reviews first.
function Get-OtherProviders([string]$Provider) {
    switch ($Provider) {
        "claude"  { return @("codex", "copilot") }
        "codex"   { return @("claude", "copilot") }
        default   { return @("claude", "codex") }
    }
}

function Get-IssueProviders([object]$Issue) {
    $author = Normalize-Provider (Get-Field $Issue.body "Provider")
    $reviewerRaw = ([string](Get-Field $Issue.body "Reviewer")).Trim().ToLowerInvariant()
    $reviewer = if ($script:AllProviders -contains $reviewerRaw) { $reviewerRaw } else { Other-Provider $author }
    if ($reviewer -eq $author) { $reviewer = Other-Provider $author }
    return [pscustomobject]@{ Author = $author; Reviewer = $reviewer }
}

# Every task needs two different providers -- one writes, another reviews -- so a provider that
# is out for hours would otherwise stall the whole queue. When the assigned author is unavailable
# for long enough to be worth it and another provider is usable, the work is handed over: the
# free provider writes the code and the assigned one reviews it when it returns. Independent
# review is preserved exactly; only who does which half changes.
function Get-EffectiveAuthor([object]$Issue) {
    $p = Get-IssueProviders $Issue
    if (Test-ProviderUsable $p.Author) { return $p.Author }
    $until = Get-ProviderCooldown $p.Author
    if (-not $until) { return $null }
    if (($until - (Get-Date)).TotalMinutes -lt $SwapAfterMinutes) { return $null }
    foreach ($other in (Get-OtherProviders $p.Author)) {
        if (Test-ProviderUsable $other) { return $other }
    }
    return $null
}

# The reviewer that will actually be asked: the assigned one when it is usable, otherwise the
# first other usable provider that is not the author. Never the author itself. Unlike the author
# swap this needs no waiting period and no issue-body rewrite: a review is a single read-only
# session, and which independent provider gives it does not change what was written.
function Get-EffectiveReviewer([object]$Issue) {
    $p = Get-IssueProviders $Issue
    if (Test-ProviderUsable $p.Reviewer) { return $p.Reviewer }
    foreach ($other in (Get-OtherProviders $p.Author)) {
        if ($other -ne $p.Reviewer -and (Test-ProviderUsable $other)) { return $other }
    }
    return $null
}

# Whether an agent-review issue can make progress THIS cycle. The label says "review", but the
# real next step may be a revision the author still owes (state field awaitingRevisionBy, set
# before a revision worker is launched and cleared once its result is pushed). That step needs
# the author -- and only the author: a revision is edits to that provider's own branch, never
# handed to another one -- so a reviewer with quota is not enough to enter Invoke-Review. Without
# this gate the loop would re-enter a review seconds after the author's quota pause, re-run the
# pre-review checks against the unchanged commit and fail a task that was never attempted.
function Test-ReviewRunnable([object]$Issue) {
    $ok = $true
    $st = Load-State ([int]$Issue.number) ([ref]$ok)
    if ($ok -and $st.awaitingRevisionBy) { return [bool](Test-ProviderUsable ([string]$st.awaitingRevisionBy)) }
    return ($null -ne (Get-EffectiveReviewer $Issue))
}

function Set-IssueProviders([object]$Issue, [string]$Author, [string]$Reviewer) {
    $n = [int]$Issue.number
    $body = [string]$Issue.body
    $rxProvider = New-Object System.Text.RegularExpressions.Regex('^Provider:[^\r\n]*$', 'Multiline')
    $rxReviewer = New-Object System.Text.RegularExpressions.Regex('^Reviewer:[^\r\n]*$', 'Multiline')
    if (-not $rxProvider.IsMatch($body) -or -not $rxReviewer.IsMatch($body)) {
        Write-Log "Issue #${n}: could not find the Provider/Reviewer lines to swap; leaving the assignment alone"
        return $false
    }
    $new = $rxProvider.Replace($body, "Provider: $Author", 1)
    $new = $rxReviewer.Replace($new, "Reviewer: $Reviewer", 1)
    $bodyFile = Join-Path $statePath "issue-$n.swap.md"
    Write-Utf8File $bodyFile $new
    $r = Invoke-Gh @("issue", "edit", "$n", "--repo", $Repository, "--body-file", $bodyFile)
    if ($r.Code -ne 0) {
        Write-Log "Issue #${n}: could not rewrite the issue body to swap providers: $($r.Text)"
        return $false
    }
    $Issue.body = $new
    return $true
}

function Register-QuotaBlock([object]$Issue, [string]$Provider, [object]$Run, [string]$Phase) {
    $until = $Run.CooldownUntil
    # Only when the provider did not say when it resets: a short, quiet wait, re-learned from the
    # next real attempt rather than escalated blindly.
    if (-not $until) { $until = (Get-Date).AddMinutes(30) }
    $why = if ($Run.QuotaMessage) { [string]$Run.QuotaMessage } else { "no allowance left" }
    # The wall belongs to the login that hit it. Only that account key rests; if the provider has
    # another login left, the same task is simply re-run with it on the next cycle.
    $key = if ($Run.PSObject.Properties["Account"] -and $Run.Account) { [string]$Run.Account } else { $Provider }
    Set-ProviderCooldown $key $until $why
    $next = Get-ReadyAccount $Provider
    $n = if ($Issue) { [int]$Issue.number } else { 0 }
    $who = if ($key -eq $Provider) { "``$Provider``" } else { "``$Provider`` (account ``$($key.Split('/')[-1])``)" }
    if ($next) {
        Write-Log "Issue #${n}: $who has no quota left during $Phase ($why). Pausing that login until $($until.ToString('yyyy-MM-dd HH:mm')); ``$Provider`` continues with account ``$($next.label)`` from the next cycle, and no attempt was used."
    } else {
        Write-Log "Issue #${n}: $who has no quota left during $Phase ($why). Pausing that provider until $($until.ToString('yyyy-MM-dd HH:mm')); the task stays queued and no attempt was used."
    }
    if ($n -gt 0) {
        # One comment per distinct reset time per login: enough for the owner to understand the
        # pause, without a comment every poll while the wall is still up.
        $stampFile = Join-Path $statePath ("quota-notice-" + ($key -replace '[\\/]', '-') + ".txt")
        $stamp = $until.ToString("o")
        $last = if (Test-Path $stampFile) { ([string](Get-Content -Raw -Path $stampFile)).Trim() } else { "" }
        if ($last -ne $stamp) {
            if ($next) {
                Comment $n "Supervisor: switching logins, not failed. $who has no usage allowance left ($why). This task continues with ``$Provider`` account ``$($next.label)`` on the next cycle; the exhausted login rests until **$($until.ToString('HH:mm'))** and no review or revision attempt was consumed."
            } else {
                Comment $n "Supervisor: paused, not failed. $who has no usage allowance left ($why). Work on this task resumes automatically after **$($until.ToString('HH:mm'))**; no review or revision attempt was consumed."
            }
            try { Set-Content -Path $stampFile -Value $stamp -Encoding ascii -ErrorAction Stop } catch { }
        }
    }
}


# ----------------------------------------------------------------------------- failure identity
# Comparing commits ("is the branch at the same commit as when these checks last failed?") is
# the wrong question: an author that commits something cosmetic each round moves the commit, so
# the gate sees "progress" while the same wall stands, and another author session is spent
# against it (one task failed the same two checks six times this way: a port already in use on
# the host, and a `$c` the task body's own command expanded to nothing).
# The right question is "is it the same FAILURE?", so the failures get an identity: their text,
# lowercased, with the volatile parts (shas, durations, timestamps, GUIDs, temp names) blanked,
# sorted and hashed. Two runs of the same wall hash alike even when the commit moved.
function Get-FailureSignature([string[]]$Failures) {
    if (-not $Failures -or @($Failures).Count -eq 0) { return "" }
    $norm = foreach ($f in @($Failures)) {
        $t = [string]$f
        $t = $t -replace '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<guid>'
        $t = $t -replace '\b[0-9a-f]{7,40}\b', '<sha>'
        $t = $t -replace '\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?(\.\d+)?([+-]\d{2}:\d{2}|Z)?', '<time>'
        $t = $t -replace '\b\d{1,2}:\d{2}(:\d{2})?\b', '<time>'
        $t = $t -replace '\(exit (-?\d+), [\d.]+s\)', '(exit $1, <dur>)'
        $t = $t -replace '\b\d+(\.\d+)?\s*(s|ms|sec|seconds?)\b', '<dur>'
        $t = $t -replace '[A-Za-z]:\\[^\s`"'']*\\(tmp|temp)\\[^\s`"'']*', '<tmp>'
        $t = ($t -replace '\s+', ' ').Trim().ToLowerInvariant()
        $t
    }
    $joined = (@($norm) | Sort-Object) -join "`n"
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = $sha1.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($joined))
    } finally { $sha1.Dispose() }
    return (([BitConverter]::ToString($bytes)) -replace '-', '').Substring(0, 16).ToLowerInvariant()
}

# Failures no revision by the author can change. They are the host's (a port already taken,
# access denied, a command that timed out or could not start) or the task body's (a command
# that does not parse, names a tool that is not there, or is one the supervisor refuses to
# run). Sending these to the author buys nothing; they go to the owner with the class named.
# Returns the class ("environment: ..." / "task-body: ...") or $null for an ordinary failure.
# Several patterns also match localised (Spanish) Windows wording of the same OS messages,
# because the host's display language decides the text PowerShell and Windows print.
function Get-FailureClass([string]$Failure) {
    $t = [string]$Failure
    if ([string]::IsNullOrWhiteSpace($t)) { return $null }
    if ($t -match '^Validation environment:') { return 'environment: required validation could not run on the host' }
    if ($t -match '(?i)EADDRINUSE|address already in use|only one usage of each socket address|(port|puerto) \d+ (is |está |esta )?(already )?in use|ya está en uso') { return "environment: a port is already in use on the host" }
    if ($t -match '(?i)\baccess (is )?denied\b|acceso denegado|permission denied|UnauthorizedAccessException|being used by another process|est[áa] siendo utilizado por otro proceso') { return "environment: access denied or a file locked on the host" }
    if ($t -match '\[timed out after \d+ s and was killed\]') { return "environment: the acceptance command timed out on the host" }
    if ($t -match '\[could not be started\]') { return "environment: the acceptance command could not be started on the host" }
    if ($t -match '(?m)^refused: this command matches') { return "task-body: the acceptance command is one the supervisor refuses to run from an issue body" }
    if ($t -match '^Lesson L-\d+ \(task-body\)') { return "task-body: an active lesson rejects an acceptance command as written in the issue body (the author cannot edit it)" }
    # A bare tool name (no path separator) that PowerShell cannot find is a missing tool on the
    # host; a script path that is not found is the author's (it was supposed to create it).
    if ($t -match "(?i)The term '[^'\\/]+' is not recognized|El t[ée]rmino '[^'\\/]+' no se reconoce") { return "environment: a command the acceptance line needs is not on the host's PATH" }
    # PowerShell's own parser rejecting the line: these names are specific to PowerShell, so a
    # syntax error in a changed .js or .py file (the author's) never lands here.
    if ($t -match '(?i)\bParserError\b|\bParseException\b|IncompleteParseException') { return "task-body: the acceptance command itself does not parse as PowerShell" }
    return $null
}

# The author's own "I cannot": a `## Blocked` section in the handoff with a fixed shape,
#
#   ## Blocked
#   reason: environment | task-body | out-of-scope
#   <one line: what is in the way>
#
# Only that section counts. An earlier one-line form (`SCOPE-BLOCKED: <paths> -- <why>`) was
# also read as out-of-scope and produced false stalls: lesson L-003 told authors to write that
# very line under `## Known limitations` for any out-of-scope file they deliberately left alone,
# so finished tasks whose acceptance commands all passed on the host were stopped for a repair
# round that changed nothing. A note about what was left untouched is bookkeeping for the
# reviewer; "I cannot finish" is the `## Blocked` section and nothing else. The fixed shape is
# what lets the loop act on a diagnosis an author would otherwise only write in prose.
# Returns @{ Reason; Detail } or $null.
function Get-HandoffBlock([string]$Handoff) {
    if ([string]::IsNullOrWhiteSpace($Handoff)) { return $null }
    $m = [regex]::Match($Handoff, '(?im)^\s*##\s*Blocked\s*$\s*^\s*(?:[-*]\s*)?reason\s*:\s*(environment|task-body|out-of-scope)\b[^\r\n]*\r?\n?((?:(?!^\s*##).*\r?\n?)*)')
    if ($m.Success) {
        $detail = (($m.Groups[2].Value -split "\r?\n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }) -join " "
        if ($detail.Length -gt 600) { $detail = $detail.Substring(0, 600).TrimEnd() + "..." }
        return @{ Reason = $m.Groups[1].Value.ToLowerInvariant(); Detail = $detail }
    }
    return $null
}

# Writes the lessons file in the main checkout and pushes it straight to origin/main. This checkout
# must be exactly origin/main before and after: a local commit that never reaches origin, or a
# modified tracked file, makes Update-Self's `git pull --ff-only` fail silently on every cycle
# from then on. On any failure the local change is discarded (it is learned again next time).
function Publish-Lessons($Lessons, [string]$LessonsPath, [string]$Message, [int]$IssueNumber) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LessonsPath) | Out-Null
    Write-Lessons -Lessons $Lessons -Path $LessonsPath | Out-Null
    $committed = $false
    Push-Location $root
    try {
        & git fetch origin main --quiet 2>&1 | Out-Null
        $behindMain = [int](& git rev-list --count HEAD..origin/main 2>$null)
        if ($behindMain -ne 0) { throw "this checkout is $behindMain commit(s) behind origin/main" }
        & git add -- $lessonsRel 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'git add failed' }
        $msg = ($Message -replace '\s+', ' ').Trim()
        if ($msg.Length -gt 140) { $msg = $msg.Substring(0, 140).TrimEnd() }
        & git commit -q -m $msg 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
        $committed = $true
        & git push origin HEAD:main 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'git push origin HEAD:main failed' }
        return $true
    } catch {
        Write-Log "Issue #${IssueNumber}: could not publish $lessonsRel ($($_.Exception.Message)); discarding the local copy so self-update keeps working"
        if ($committed) { & git reset -q --soft origin/main 2>&1 | Out-Null }
        & git reset -q origin/main -- $lessonsRel 2>&1 | Out-Null
        & git checkout -- $lessonsRel 2>&1 | Out-Null
        # A file that did not exist on origin/main yet (the first learned lesson) is removed again.
        & git cat-file -e "origin/main:$lessonsRel" 2>$null
        if ($LASTEXITCODE -ne 0) { Remove-Item -LiteralPath $LessonsPath -Force -ErrorAction SilentlyContinue }
        return $false
    } finally { Pop-Location }
}

# A capability an author was found to lack (from the repair step) becomes a pinned, permanent
# rule every future author reads: what is missing, why, and the workaround that does work from
# inside the sandbox. Pinned so the prompt cap never drops it.
function Add-CapabilityLesson([int]$IssueNumber, [string]$Missing, [string]$Reason, [string]$Workaround) {
    $readPath = Get-LessonsReadPath
    if (-not $readPath) { return $false }
    # A permanent rule every author reads must be general and actionable from the sandbox: a
    # workaround of "none" is a host-side fix, not an author lesson, and a narrative that names
    # commits or runs past a few hundred characters is a task post-mortem, not a rule.
    if ($Workaround -match '^\s*(none|nothing|n/?a)\b') { Write-Log "Issue #${IssueNumber}: capability lesson not recorded (no author-side workaround): $Missing"; return $false }
    if (($Missing + ' ' + $Reason).Length -gt 400 -or ($Missing + ' ' + $Reason + ' ' + $Workaround) -match '\b[0-9a-f]{7,40}\b') { Write-Log "Issue #${IssueNumber}: capability lesson not recorded (task-specific narrative, not a general rule): $Missing"; return $false }
    $lessons = Read-Lessons -Path $readPath
    $rule = "Authors cannot $Missing ($Reason)."
    $dup = @($lessons.Active | Where-Object { $_.rule -and (Test-RuleSimilarity -RuleA $rule -RuleB ([string]$_.rule) -Threshold 0.65) })
    if ($dup.Count -gt 0) { $dup[0].hits = [int]$dup[0].hits + 1; $dup[0].lastSeen = (Get-Date -Format 'yyyy-MM-dd') }
    else {
        $lessons.Active += [PSCustomObject]@{
            id = (New-LessonId -Lessons $lessons); date = (Get-Date -Format 'yyyy-MM-dd'); rule = $rule
            doInstead = $(if ($Workaround) { $Workaround } else { "Say so in the handoff's ## Blocked section (reason: environment) instead of working around it." })
            check = $null; checkOn = $null; source = "capability (task #$IssueNumber)"; hits = 0; lastSeen = (Get-Date -Format 'yyyy-MM-dd'); pinned = $true
        }
    }
    return (Publish-Lessons $lessons $lessonsFilePath "chore(lessons): authors cannot $Missing" $IssueNumber)
}

# ----------------------------------------------------------------------------- self-repair
# Nothing below should end with a person unless a person is genuinely the only one who can act.
# When a task stops (same failure twice, a finding restated three rounds, a `## Blocked`
# handoff, the round ceiling, a defective task text) the supervisor first asks the strongest
# model, read-only, to decide what the PIPELINE should change -- the task text, its owned
# paths, or the author's instructions -- applies that, resets the counters and continues. The
# owner is asked only when the repair step itself says the host or a product decision is in the
# way, or when the repair budget (-MaxRepairs) is spent.

function Set-IssueBody([int]$Number, [string]$Body) {
    $f = Join-Path $statePath "issue-$Number.body.md"
    Write-Utf8File $f $Body
    $r = Invoke-Gh @("issue", "edit", "$Number", "--repo", $Repository, "--body-file", $f)
    return ($r.Code -eq 0)
}

# The one task-body defect the supervisor can repair without judgement: a nested
# `powershell -Command "..."` acceptance line (the planner keeps writing them, and the outer
# shell expands every `$name` before the inner one runs) becomes its quoted text. Returns $true
# when the issue body was changed.
function Repair-NestedAcceptanceCommands([object]$Issue) {
    $body = [string]$Issue.body
    $m = [regex]::Match($body, '(?ms)^(##\s*Acceptance commands\s*\r?\n\s*```[^\r\n]*\r?\n)(.*?)(\r?\n\s*```)')
    if (-not $m.Success) { return $false }
    $changed = $false
    $lines = @(foreach ($line in ($m.Groups[2].Value -split "\r?\n")) {
        $x = [regex]::Match($line, '^\s*powershell(?:\.exe)?\s+(?:-NoProfile\s+)?(?:-ExecutionPolicy\s+\S+\s+)?-Command\s+"(.*)"\s*$')
        if ($x.Success) { $changed = $true; ($x.Groups[1].Value -replace '\\"', '"') } else { $line }
    })
    if (-not $changed) { return $false }
    $newBody = $body.Substring(0, $m.Groups[2].Index) + ($lines -join "`n") + $body.Substring($m.Groups[2].Index + $m.Groups[2].Length)
    if (-not (Set-IssueBody ([int]$Issue.number) $newBody)) { return $false }
    Comment ([int]$Issue.number) "Supervisor: the acceptance commands were written as nested ``powershell -Command`` lines, which cannot work from an issue body. Rewrote them as their quoted text and continuing; no author or review round was spent."
    return $true
}

function Invoke-Repair([object]$Issue, [string]$Kind, [string]$Failure, [string]$Worktree, [string]$Branch) {
    $n = [int]$Issue.number
    $st = Load-State $n
    if (Queue-ExpertRecovery $Issue $st $Kind $Failure $Worktree) { return }
    $attempt = [int]$st.repairs + 1
    if ($attempt -gt $MaxRepairs) {
        Report-Failure $Issue "$Failure`n`nThe repair step has already changed this task $([int]$st.repairs) time(s) without unblocking it, so a person has to decide."
        return
    }
    $provider = $PlannerProvider
    if (-not (Test-ProviderUsable $provider)) { Write-Log "Issue #${n}: repair needed ($Kind) but ``$provider`` has no allowance right now; the task waits, unchanged, until it is back"; return }
    try { Write-Live -Tag "issue-$n-repair-$attempt" -Provider $provider -StartedAtUtc (Get-Date).ToUniversalTime() -Deadline "" -Role "supervisor" -Step "repair" -Summary "deciding how to unblock issue #$n ($Kind)" } catch { }
    Comment $n "Supervisor: the task stopped ($Kind). Before asking a person, the repair step (``$provider``, attempt $attempt of $MaxRepairs) is reading the failure, the task and the contracts to decide what to change."
    $workDir = if ($Worktree -and (Test-Path $Worktree)) { $Worktree } else { $root }
    $handoff = "(none)"
    try { if ($Worktree -and (Test-Path $Worktree)) { $handoff = Limit-Text (Read-Handoff $Worktree) 3500 "handoff" } } catch { }
    $lastReview = "(none)"
    $reviewFiles = @(Get-ChildItem -Path $statePath -Filter "issue-$n.review-*.md" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($reviewFiles.Count -gt 0) { try { $lastReview = Limit-Text ([string](Get-Content -Raw $reviewFiles[0].FullName -Encoding utf8)) 4000 "review" } catch { } }
    $acc = "(none executed)"
    $accFile = Join-Path $statePath "issue-$n.acceptance.md"
    if (Test-Path $accFile) { try { $acc = Limit-Text ([string](Get-Content -Raw $accFile -Encoding utf8)) 4000 "acceptance" } catch { } }
    $objRef = Get-IssueRefs (Get-Field $Issue.body "Objective")
    $objNum = if ($objRef.Count -gt 0) { [int]$objRef[0] } else { 0 }
    $objBody = "(no objective linked)"
    if ($objNum -gt 0) { $o = Get-Issue $objNum; if ($o) { $objBody = Limit-Text ([string]$o.body) 4000 "objective" } }
    $prompt = Fill-Template "repairer" @{ REPOSITORY = $Repository; BRANCH = $Branch; ATTEMPT = $attempt; MAX_ATTEMPTS = $MaxRepairs; FAILURE = $Failure; ISSUE_NUMBER = $n; ISSUE_BODY = [string]$Issue.body; OBJECTIVE_NUMBER = $objNum; OBJECTIVE_BODY = $objBody; HANDOFF = $handoff; LAST_REVIEW = $lastReview; ACCEPTANCE = $acc; LESSONS = (Get-LessonsSection) }
    $run = Invoke-Agent -Provider $provider -Mode readonly -Prompt $prompt -WorkDir $workDir -Tag "issue-$n-repair-$attempt" -TimeoutMinutes 25
    if ($run.QuotaBlocked) { Register-QuotaBlock $Issue $provider $run "repair"; return }
    $d = $null
    if (-not $run.TimedOut -and -not $run.Unsafe) { $d = Extract-Json $run.Output }
    if ((-not $d -or -not $d.decision) -and -not $run.TimedOut -and -not $run.Unsafe) {
        # A read-only session that produced no JSON is usually a truncated or chatty answer, not a
        # verdict on the task; without a retry, one unparseable reply sends the task to the owner with
        # the repair budget untouched. One more try with the same prompt, same attempt.
        Write-Log "Issue #${n}: repair step returned no usable decision; retrying once"
        $run = Invoke-Agent -Provider $provider -Mode readonly -Prompt $prompt -WorkDir $workDir -Tag "issue-$n-repair-$attempt-retry" -TimeoutMinutes 25
        if ($run.QuotaBlocked) { Register-QuotaBlock $Issue $provider $run "repair"; return }
        if (-not $run.TimedOut -and -not $run.Unsafe) { $d = Extract-Json $run.Output }
    }
    if (-not $d -or -not $d.decision) {
        $st.repairs = $attempt
        Save-State $n $st | Out-Null
        Report-Failure $Issue "$Failure`n`nThe repair step ran twice but did not return a usable decision, so a person has to decide."
        return
    }
    $decision = ("$($d.decision)").Trim().ToLowerInvariant()
    $explain = ("$($d.explanation)").Trim()
    $applied = $false
    $stopForHost = $null
    switch ($decision) {
        "patch-task" {
            $body = [string]$Issue.body
            $pairs = @($d.patches | Where-Object { $_ -and "$($_.find)" -ne "" })
            $okAll = ($pairs.Count -gt 0)
            foreach ($pair in $pairs) {
                $find = [string]$pair.find
                $first = $body.IndexOf($find, [System.StringComparison]::Ordinal)
                if ($first -lt 0 -or $body.IndexOf($find, $first + 1, [System.StringComparison]::Ordinal) -ge 0) { $okAll = $false; Write-Log "Issue #${n}: repair patch text not found exactly once: $find"; break }
                $body = $body.Substring(0, $first) + [string]$pair.replace + $body.Substring($first + $find.Length)
            }
            if ($okAll -and ($body -match '(?m)^Provider:') -and (Set-IssueBody $n $body)) {
                $applied = $true
                Comment $n "Supervisor (repair step): corrected $($pairs.Count) line(s) of the task text. $explain`n`nThe existing commits are kept; the checks and the next review use the corrected task."
            }
        }
        "capability" {
            $cap = $d.capability
            $missing = ("$($cap.missing)").Trim(); $reason = ("$($cap.reason)").Trim()
            $workaround = ("$($cap.workaround)").Trim(); $hostAction = ("$($cap.host_action)").Trim()
            if ($missing) {
                $recorded = $false
                try { $recorded = Add-CapabilityLesson $n $missing $reason $workaround } catch { Write-Log "Issue #${n}: could not record the capability lesson: $($_.Exception.Message)" }
                $note = "Supervisor (repair step): the author cannot **$missing** -- $reason. $explain"
                if ($recorded) { $note += "`n`nRecorded as a permanent rule for every future author$(if ($workaround) { ': ' + $workaround })." }
                if ($hostAction) {
                    $stopForHost = "The author cannot **$missing** ($reason) and nothing works around it from inside the sandbox. **What to do on the host:** $hostAction`n`n$explain"
                    Comment $n $note
                } else {
                    $st.repairHint = $(if ($workaround) { "You cannot $missing ($reason). Do this instead: $workaround" } else { "You cannot $missing ($reason). Complete the task without it and state the limitation in the handoff." })
                    $applied = $true
                    Comment $n "$note`n`nThe task continues with that workaround."
                }
            }
        }
        "switch-author" {
            $current = (Get-IssueProviders $Issue).Author
            $candidates = @(Get-OtherProviders $current | Where-Object { Test-ProviderUsable $_ })
            $wanted = ("$($d.new_author)").Trim().ToLowerInvariant()
            $new = $null
            if ($wanted -and ($candidates -contains $wanted)) { $new = $wanted } elseif ($candidates.Count -gt 0) { $new = $candidates[0] }
            if ($new -and -not $st.authorSwitched) {
                if (Set-IssueProviders $Issue $new $current) {
                    $applied = $true
                    $st.authorSwitched = $true
                    # Handing over is not the same as a task defect: it does not spend the repair budget.
                    $attempt = $attempt - 1
                    Comment $n "Supervisor (repair step): handing this task from ``$current`` to ``$new``; ``$current`` becomes its reviewer. The branch and its commits are kept and ``$new`` continues from them. $explain"
                }
            } else { Write-Log "Issue #${n}: repair step asked to switch author but no other provider is usable or the author was already switched once" }
        }
        "rewrite-task" {
            $body = [string]$d.body
            $ok = $body -and ($body -match '(?m)^Provider:') -and ($body -match '(?m)^##\s*Owned paths') -and ($body -match '(?m)^##\s*Acceptance')
            if ($ok -and (Set-IssueBody $n $body)) {
                $applied = $true
                Comment $n "Supervisor (repair step): the task text was the problem and has been corrected. $explain`n`nThe existing commits are kept; the checks and the next review use the corrected task."
            } else { Write-Log "Issue #${n}: repair step returned a rewrite without the required sections; not applied" }
        }
        "rescope" {
            $add = @($d.add_owned_paths | ForEach-Object { "$_".Trim() } | Where-Object { $_ -and -not (Test-PathUnderForbidden -Path $_ -Forbidden $script:OwnershipRules.protectedPaths) })
            $body = [string]$Issue.body
            $m = [regex]::Match($body, '(?ms)^##\s*Owned paths\s*\r?\n(.*?)(?=^##\s|\z)')
            if ($add.Count -gt 0 -and $m.Success) {
                $insert = (($add | ForEach-Object { "- ``$_``" }) -join "`n")
                $pos = $m.Groups[1].Index + $m.Groups[1].Length
                $body = $body.Substring(0, $pos).TrimEnd("`r", "`n") + "`n" + $insert + "`n`n" + $body.Substring($pos).TrimStart("`r", "`n")
                if (Set-IssueBody $n $body) {
                    $applied = $true
                    Comment $n "Supervisor (repair step): the task needed files it did not own; added $(($add | ForEach-Object { '``' + $_ + '``' }) -join ', ') to its owned paths. $explain"
                }
            }
        }
        "hint" {
            $hint = ("$($d.hint)").Trim()
            if ($hint) {
                $st.repairHint = $hint
                $applied = $true
                Comment $n "Supervisor (repair step): the previous revision missed the requirement; the next revision gets explicit instructions. $explain"
            }
        }
    }
    # `add_owned_paths` is honoured with EVERY applied decision, not only `rescope`: the repair
    # model lists every file it authorises there whatever its main decision. Applying only the
    # patches of a `patch-task` leaves the author blocked on exactly the files the repair step
    # named, with the repair budget already spent. Files already covered by an owned entry are skipped.
    if ($applied -and $decision -ne "rescope") {
        $extra = @($d.add_owned_paths | ForEach-Object { "$_".Trim() } | Where-Object { $_ -and -not (Test-PathUnderForbidden -Path $_ -Forbidden $script:OwnershipRules.protectedPaths) })
        if ($extra.Count -gt 0) {
            try {
                $latest = Get-Issue $n
                $bodyNow = if ($latest -and $latest.body) { [string]$latest.body } else { [string]$Issue.body }
                $ownedNow = @(Get-OwnedPaths $bodyNow)
                $missingPaths = @($extra | Where-Object { -not (Test-PathCovered -Path $_ -OwnedPaths $ownedNow) })
                if ($missingPaths.Count -gt 0) {
                    $adds = @($missingPaths | ForEach-Object { [pscustomobject]@{ Path = $_; Marker = "(auto: authorised by the repair step with its $decision)" } })
                    $widened = Add-OwnedPathsToBody -Body $bodyNow -Additions $adds
                    if ($widened -and (Set-IssueBody $n $widened)) {
                        Comment $n "Supervisor (repair step): the same decision also authorised $(($missingPaths | ForEach-Object { '``' + $_ + '``' }) -join ', '); added to ## Owned paths."
                    } else {
                        Write-Log "Issue #${n}: repair decision ``$decision`` listed add_owned_paths but the body could not be widened"
                    }
                }
            } catch { Write-Log "Issue #${n}: could not apply add_owned_paths from a ``$decision`` repair: $($_.Exception.Message)" }
        }
    }
    # A rescope (owned paths widened) is cheap, safe and bounded by the file list, so it does not
    # spend the repair budget; otherwise a task can use every repair on rescopes and have none left
    # for the rewrite it actually needs. Free is not unlimited, though: the first three rescopes of
    # a task are free, from the fourth on a rescope costs a repair like any other decision, so a
    # task that keeps discovering one more file it needs still reaches the repair ceiling instead of
    # cycling forever.
    if ($applied -and $decision -eq "rescope") { $st.rescopes = [int]$st.rescopes + 1 }
    $freeRescope = ($applied -and $decision -eq "rescope" -and [int]$st.rescopes -le 3)
    $st.repairs = if ($freeRescope) { [int]$st.repairs } else { $attempt }
    if (-not $applied) {
        Save-State $n $st | Out-Null
        if ($stopForHost) { Report-Failure $Issue "$Failure`n`n$stopForHost" } else { Report-Failure $Issue "$Failure`n`n**What the repair step found:** $explain" }
        return
    }
    # Reset per-attempt diagnosis state; repair and cumulative correction budgets survive.
    $st.lastAutoFailureSha = $null; $st.lastAutoFailureSignature = $null; $st.restatedRounds = 0; $st.findingStreaks = @()
    # (blockedHandledSha is kept on purpose: the `## Blocked` section is still in the handoff
    # until the next revision strips it, and clearing the record would make it fire again.)
    $st.lastReviewedSha = $null; $st.lastVerdict = $null; $st.reviewFailures = 0
    # The revision count starts over only for a genuinely new attempt (a rewritten or patched
    # task, a fixed environment, another author). A rescope or a hint continues the same attempt
    # in the same worktree, so the revision ceiling keeps counting; otherwise consecutive rescopes
    # could reset it indefinitely. Two rounds are always left so the widened scope or the hint gets
    # a real try.
    if ($decision -in @("rescope", "hint")) { $st.revisions = [Math]::Max(0, [Math]::Min([int]$st.revisions, $MaxRevisions - 2)) }
    else { $st.revisions = 0 }
    $pr = $null
    try { if ($Branch) { $pr = Find-PR $Branch } } catch { }
    if ($pr -and $decision -in @("rescope", "hint", "patch-task", "rewrite-task")) {
        $st.pendingRevision = @{ text = "$Failure`n`n$lastReview`n`nRepair decision: $explain"; by = "task repair" }
        $st.awaitingRevisionBy = (Get-IssueProviders $Issue).Author
    }
    if (-not (Save-State $n $st)) { Report-Failure $Issue "Could not save the repair transition; no agent dispatched."; return }
    if ($pr) { Set-IssueLabels $n @($L.Failed, $L.Ready, $L.InProgress) @($L.Review) } else { Set-IssueLabels $n @($L.Failed, $L.Review, $L.InProgress) @($L.Ready) }
    Write-Log "Issue #${n}: repair step ($Kind) applied decision ``$decision``; continuing without a person"
}

# ----------------------------------------------------------------------------- mechanical checks
# Everything a script can decide, a script decides -- before a paid reviewer is ever asked. These
# are the checks that were costing whole review rounds to discover (a parse error, stray
# whitespace, a change reaching outside its allowed paths, a red test).
# Runs one external command with a wall-clock bound, killing its whole process tree on
# timeout. Returns @{ Code; Output; TimedOut }. Used for the test gate and the pre-push command:
# a test that never exits otherwise blocks the supervisor forever (one such test once kept the
# whole pipeline hung for 8.5 hours).
function Invoke-BoundedCommand([string]$FilePath, [string]$Arguments, [string]$WorkingDirectory, [int]$TimeoutSeconds) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($FilePath -match '\.(cmd|bat)$') { $psi.FileName = "cmd.exe"; $psi.Arguments = "/c `"`"$FilePath`" $Arguments`"" }
    else { $psi.FileName = $FilePath; $psi.Arguments = $Arguments }
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $code = -3; $timedOut = $false; $text = ""
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
        if ($p.WaitForExit($TimeoutSeconds * 1000)) { $p.WaitForExit(); $code = $p.ExitCode }
        else { & taskkill /T /F /PID $p.Id 2>&1 | Out-Null; $code = -2; $timedOut = $true }
        [System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), 5000) | Out-Null
        if ($outTask.IsCompleted) { $text += [string]$outTask.Result }
        if ($errTask.IsCompleted) { $text += "`n" + [string]$errTask.Result }
    } catch { $code = -3; $text += "`n[could not be started: $($_.Exception.Message)]" }
    return @{ Code = $code; Output = $text; TimedOut = $timedOut }
}

# Tool processes that never exit (a headless engine whose test never quits, a dev server a test
# forgot to stop) outlive their launcher. Started under this supervisor -- by an agent's shell or
# by the test gate -- they inherit the scheduled task's stdout handle (task-stdout.txt), and while
# they live the wrapper loop cannot reopen that file, so a self-update restart silently never
# comes back. Only processes whose name matches the configured `orphanSweep.processNames` (and,
# when set, whose command line contains `orphanSweep.commandLineContains`) are ever touched; with
# nothing configured the sweep does nothing.
#
# "Orphaned" is judged on the whole launch chain, not just the direct parent: an agent's
# `sh -c "tool --headless ... | tail"` leaves sh.exe -> console launcher -> tool all alive with
# only the agent (sh's parent) gone, which a direct-parent check cannot see. Test-OrphanChain
# climbs through shell/launcher links (sh, bash, cmd, powershell, node, python, the configured
# tool names...) and calls the process orphaned as soon as one link's parent is missing or is a
# recycled PID (a "parent" younger than its child). The climb stops, without a verdict of
# orphaned, at the first non-launcher process (a terminal, an editor, the desktop shell): a copy
# of the tool the owner started from a terminal is never touched even though explorer.exe's own
# parent is long gone.
function Test-OrphanChain([int]$ProcId, [hashtable]$ProcessTable, [string[]]$ExtraLinks = $script:OrphanProcessNames) {
    # $ProcessTable: pid -> @{ Parent = <int>; Name = <string>; Started = <datetime> } for every live process.
    $links = @('sh', 'bash', 'cmd', 'powershell', 'pwsh', 'node', 'python', 'claude', 'codex', 'copilot') + @($ExtraLinks | Where-Object { $_ })
    $current = $ProcId
    for ($depth = 0; $depth -lt 12; $depth++) {
        if (-not $ProcessTable.ContainsKey($current)) { return $true }
        $me = $ProcessTable[$current]
        $parentId = [int]$me.Parent
        if ($parentId -le 0) { return $false }
        if (-not $ProcessTable.ContainsKey($parentId)) { return $true }
        $parent = $ProcessTable[$parentId]
        if ($parent.Started -and $me.Started -and $parent.Started -gt $me.Started.AddSeconds(1)) { return $true }
        $parentBase = ([string]$parent.Name) -replace '\.exe$', ''
        $isLink = $false
        foreach ($link in $links) { if ($parentBase -like "$link*") { $isLink = $true; break } }
        if (-not $isLink) { return $false }
        $current = $parentId
    }
    return $false
}

# Whether a process is one the orphan sweep may consider at all: its executable name starts with
# one of the configured names and, when a command-line filter is configured, its command line
# contains it. Pure.
function Test-OrphanCandidate([string]$Name, [string]$CommandLine, [string[]]$Names, [string]$CommandLineContains) {
    $base = ([string]$Name) -replace '\.exe$', ''
    $match = $false
    foreach ($n in @($Names | Where-Object { $_ })) { if ($base -like "$n*") { $match = $true; break } }
    if (-not $match) { return $false }
    if ($CommandLineContains) { return ([string]$CommandLine).IndexOf($CommandLineContains, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }
    return $true
}

function Stop-OrphanedProcesses([string]$Context) {
    if ($DryRun -or @($script:OrphanProcessNames).Count -eq 0) { return }
    try {
        $all = @(Get-CimInstance Win32_Process -ErrorAction Stop)
        $table = @{}
        foreach ($x in $all) { $table[[int]$x.ProcessId] = @{ Parent = [int]$x.ParentProcessId; Name = [string]$x.Name; Started = $x.CreationDate } }
        foreach ($x in $all) {
            if (-not (Test-OrphanCandidate ([string]$x.Name) ([string]$x.CommandLine) $script:OrphanProcessNames $script:OrphanCommandLineContains)) { continue }
            if (-not (Test-OrphanChain ([int]$x.ProcessId) $table)) { continue }
            try { Stop-Process -Id $x.ProcessId -Force -ErrorAction Stop; Write-Log "[$Context] killed orphaned $($x.Name) process $($x.ProcessId) (started $($x.CreationDate.ToString('HH:mm:ss'))): its launcher chain is gone" } catch { }
        }
    } catch { }
}

# ----------------------------------------------------------------------------- leaked log-file holders
# Everything this supervisor starts with inherited handles -- the agent worker, and through it
# the agent's shells, test tools, tails -- receives a copy of the wrapper's stdout/stderr file
# handles: supervisor-loop.cmd opens task-stdout.txt / task-stderr.txt with a share mode that
# admits no second writer. A descendant that outlives its run keeps those files open, and the
# wrapper then cannot reopen them to relaunch the supervisor after a self-update exit. In
# practice, four `sh -c "<tool> --headless ... | tail"` chains an agent left behind once blocked
# the relaunch for an hour.
#
# The Windows Restart Manager answers the exact question -- which processes hold this file open --
# with no guessing about names or parents, so the sweep kills precisely the leak set: every holder
# of this process's own stdout/stderr files (and of the canonical task-*.txt names, in case this
# instance was launched on a rotated name) that is neither this process nor one of its ancestors
# (the cmd.exe wrapper holds them legitimately). It runs only when nothing is in flight: at
# startup, after each agent run returns, and right before a self-update exit. A dry run never
# kills anything.
function Initialize-ProcessInterop {
    if (([System.Management.Automation.PSTypeName]'GdProcessInterop').Type) { return $true }
    $source = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class GdProcessInterop {
    [StructLayout(LayoutKind.Sequential)] public struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)] public string strServiceShortName;
        public int ApplicationType; public uint AppStatus; public uint TSSessionId; [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }
    [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)] public static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);
    [DllImport("rstrtmgr.dll")] public static extern int RmEndSession(uint pSessionHandle);
    [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)] public static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames, uint nApplications, [In] RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);
    [DllImport("rstrtmgr.dll")] public static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo, [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern uint GetFinalPathNameByHandle(IntPtr hFile, StringBuilder lpszFilePath, uint cchFilePath, uint dwFlags);
    public static DateTime ToUtc(System.Runtime.InteropServices.ComTypes.FILETIME ft) {
        long ticks = ((long)(uint)ft.dwHighDateTime << 32) | (uint)ft.dwLowDateTime;
        return DateTime.FromFileTimeUtc(ticks);
    }
}
'@
    try { Add-Type -TypeDefinition $source -ErrorAction Stop; return $true }
    catch { Write-Log "Process interop (Restart Manager) unavailable: $($_.Exception.Message)"; return $false }
}

function Get-StdHandleFilePath([int]$StdHandleId) {
    # -11 = STD_OUTPUT_HANDLE, -12 = STD_ERROR_HANDLE. $null when the handle is not a file on disk
    # (a console, a pipe, NUL): GetFinalPathNameByHandle only resolves file-system objects.
    try {
        if (-not (Initialize-ProcessInterop)) { return $null }
        $h = [GdProcessInterop]::GetStdHandle($StdHandleId)
        if ($h -eq [IntPtr]::Zero -or $h -eq [IntPtr](-1)) { return $null }
        $sb = New-Object System.Text.StringBuilder 2048
        $n = [GdProcessInterop]::GetFinalPathNameByHandle($h, $sb, 2048, 0)
        if ($n -eq 0 -or $n -gt 2048) { return $null }
        $path = $sb.ToString()
        if ($path.StartsWith('\\?\UNC\')) { $path = '\\' + $path.Substring(8) } elseif ($path.StartsWith('\\?\')) { $path = $path.Substring(4) }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        return $path
    } catch { return $null }
}

function Get-FileHolders([string[]]$Paths) {
    # Every process with an open handle on any of $Paths, as @{ Pid; App; StartedUtc }.
    $holders = @()
    $existing = @($Paths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -Unique)
    if ($existing.Count -eq 0) { return $holders }
    if (-not (Initialize-ProcessInterop)) { return $holders }
    $session = [uint32]0
    if ([GdProcessInterop]::RmStartSession([ref]$session, 0, [Guid]::NewGuid().ToString()) -ne 0) { return $holders }
    try {
        if ([GdProcessInterop]::RmRegisterResources($session, [uint32]$existing.Count, [string[]]$existing, [uint32]0, $null, [uint32]0, $null) -ne 0) { return $holders }
        $needed = [uint32]0; $count = [uint32]0; $reasons = [uint32]0
        [GdProcessInterop]::RmGetList($session, [ref]$needed, [ref]$count, $null, [ref]$reasons) | Out-Null
        if ($needed -eq 0) { return $holders }
        $info = New-Object 'GdProcessInterop+RM_PROCESS_INFO[]' ([int]$needed)
        $count = $needed
        if ([GdProcessInterop]::RmGetList($session, [ref]$needed, [ref]$count, $info, [ref]$reasons) -ne 0) { return $holders }
        for ($i = 0; $i -lt [int]$count; $i++) {
            $started = $null
            try { $started = [GdProcessInterop]::ToUtc($info[$i].Process.ProcessStartTime) } catch { }
            $holders += [pscustomobject]@{ Pid = [int]$info[$i].Process.dwProcessId; App = [string]$info[$i].strAppName; StartedUtc = $started }
        }
    } finally { [GdProcessInterop]::RmEndSession($session) | Out-Null }
    return $holders
}

function Get-AncestorPids([int]$ProcId) {
    $ids = @()
    $current = $ProcId
    for ($depth = 0; $depth -lt 16; $depth++) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction SilentlyContinue
        if (-not $p -or -not $p.ParentProcessId -or [int]$p.ParentProcessId -le 0) { break }
        $ids += [int]$p.ParentProcessId
        $current = [int]$p.ParentProcessId
    }
    return $ids
}

function Select-LeakedHolders($Holders, [int]$SelfPid, [int[]]$ProtectedPids) {
    # Pure: the holders that are neither this process nor one of the protected (ancestor) PIDs.
    $keep = @{}
    $keep[$SelfPid] = $true
    foreach ($id in @($ProtectedPids)) { $keep[[int]$id] = $true }
    return @($Holders | Where-Object { $_ -and -not $keep.ContainsKey([int]$_.Pid) })
}

function Get-LiveWorkerTreePids {
    # PIDs of every agent worker recorded as running (*.worker.json) plus their whole process
    # trees. A worker that outlived a supervisor restart is adopted by the next instance
    # (Get-LiveWorkerForIssue), so at startup its processes hold the log files legitimately.
    $ids = @()
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $statePath -Filter "*.worker.json" -File -ErrorAction SilentlyContinue)) {
            $rec = $null
            try { $rec = Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json } catch { continue }
            if (-not $rec -or [int]$rec.pid -le 0) { continue }
            if (-not (Get-Process -Id ([int]$rec.pid) -ErrorAction SilentlyContinue)) { continue }
            $ids += @(Get-ProcessTreeIds ([int]$rec.pid))
        }
    } catch { }
    return $ids
}

function Stop-LeakedLogHolders([string]$Context) {
    if ($DryRun) { return }
    try {
        $paths = @((Get-StdHandleFilePath -StdHandleId (-11)), (Get-StdHandleFilePath -StdHandleId (-12)), (Join-Path $statePath "task-stdout.txt"), (Join-Path $statePath "task-stderr.txt"))
        $holders = @(Get-FileHolders $paths)
        if ($holders.Count -eq 0) { return }
        $protected = @(Get-AncestorPids $PID) + @(Get-LiveWorkerTreePids)
        $leaked = @(Select-LeakedHolders $holders $PID $protected)
        foreach ($h in $leaked) {
            $p = Get-Process -Id $h.Pid -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            # PID reuse guard: the Restart Manager reports the holder's start time; a live process
            # with that PID but a different start time is somebody else.
            try { if ($h.StartedUtc -and [Math]::Abs(($p.StartTime.ToUniversalTime() - $h.StartedUtc).TotalSeconds) -gt 2) { continue } } catch { }
            try {
                Stop-Process -Id $h.Pid -Force -ErrorAction Stop
                Write-Log "[$Context] killed leaked $($p.ProcessName) $($h.Pid) (started $($p.StartTime.ToString('HH:mm:ss'))): it outlived the run that started it and still held the supervisor's log file open, which would have blocked the next relaunch"
            } catch { Write-Log "[$Context] could not kill leaked $($p.ProcessName) $($h.Pid): $($_.Exception.Message)" }
        }
    } catch { Write-Log "[$Context] leaked-holder sweep failed: $($_.Exception.Message)" }
}

function Remove-StaleRotatedLogs {
    # supervisor-loop.cmd logs to task-stdout.<n>.txt / task-stderr.<n>.txt only while the
    # canonical file is held by a leak the sweep above has since removed; those files stop
    # growing after that relaunch and are dropped after a week.
    try {
        Get-ChildItem -LiteralPath $statePath -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^task-std(out|err)\.\d+\.txt$' -and $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}

# The project's own test command (the "test gate"), run by the supervisor on the host in the
# task worktree before every review. Returns one failure string (with the tail of the output),
# or nothing when the gate is disabled or passes. A red gate goes back to the author as a
# revision with the real output, under the same same-failure and `## Blocked` protections as any
# other pre-review check. A command that cannot be started is an environment failure, which the
# author cannot fix; a command that times out is the author's (a test that never exits).
function Get-TestGateFailures([string]$Worktree, [string]$Command = $TestCommand, [int]$TimeoutSeconds = $TestGateTimeoutSeconds) {
    if ([string]::IsNullOrWhiteSpace($Command)) { return @() }
    if (-not (Test-Path -LiteralPath $Worktree -PathType Container)) { return @('Validation environment: the task checkout is missing; the test gate could not run.') }
    Stop-OrphanedProcesses "test-gate"
    $wrapped = "`$ErrorActionPreference = 'Continue'; & { $Command }; if (`$LASTEXITCODE) { exit `$LASTEXITCODE } elseif (-not `$?) { exit 1 } else { exit 0 }"
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($wrapped))
    try { $r = Invoke-BoundedCommand "powershell.exe" "-NoProfile -NonInteractive -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand $encoded" $Worktree $TimeoutSeconds }
    catch {
        Write-Log "Test gate could not be completed in ${Worktree}: $($_.Exception.Message)"
        return @("Validation environment: the test gate could not be completed: $($_.Exception.Message)")
    }
    $tail = ((($r.Output -split "\r?\n") | Where-Object { $_ -notmatch '^\s*(#< CLIXML|<Objs )' } | Select-Object -Last 30) -join "`n")
    if ($r.TimedOut) {
        return @("The test gate (``$Command``) did not finish within $TimeoutSeconds s and was killed. Every test must terminate on its own, on every path (including early returns and failures); something kept running. Last output:`n``````n$tail`n``````")
    }
    if ($r.Code -eq -3) { return @("Validation environment: the test gate command (``$Command``) could not be started on the host.") }
    if ($r.Code -ne 0) {
        return @("The test gate (``$Command``) failed (exit $($r.Code)). Read the failing tests and trace your change against them; the output on the host was:`n``````n$tail`n``````")
    }
    return @()
}

function Get-BudgetFailures([string]$Worktree, [string[]]$Changed) {
    $fails = @()
    $budgetRel = ([string]$script:OwnershipRules.budgetsFile -replace '\\', '/').Trim('/')
    if (-not $budgetRel) { return $fails }
    $decisionsRel = ([string]$script:OwnershipRules.decisionsDirectory -replace '\\', '/').Trim('/')
    if (-not $decisionsRel) { $decisionsRel = 'docs/decisions' }
    $budgetPath = Join-Path $Worktree ($budgetRel -replace '/', '\')
    if (-not (Test-Path $budgetPath)) { return $fails }
    $budgets = $null
    try { $budgetText = Get-Content -Raw $budgetPath -Encoding utf8 -ErrorAction Stop } catch { return @("Validation environment: could not read ``$budgetRel``: $($_.Exception.Message)") }
    try { $budgets = $budgetText | ConvertFrom-Json -ErrorAction Stop } catch { return @("``$budgetRel`` is not valid JSON: $($_.Exception.Message)") }
    if (@($Changed | Where-Object { $_ -eq $budgetRel }).Count -gt 0 -and @($Changed | Where-Object { $_.StartsWith("$decisionsRel/", [System.StringComparison]::OrdinalIgnoreCase) -and $_ -match '\.md$' }).Count -eq 0) {
        $fails += "``$budgetRel`` was changed without a decision record: a file budget is a design decision, so the same change must add or amend a document under ``$decisionsRel/`` explaining why the file may grow."
    }
    foreach ($prop in $budgets.PSObject.Properties) {
        if ($prop.Name.StartsWith("_")) { continue }
        $rel = [string]$prop.Name
        $max = 0
        try { $max = [int]$prop.Value } catch { $fails += "``$budgetRel`` has an invalid line limit for ``$rel``."; continue }
        if ($max -le 0) { $fails += "``$budgetRel`` needs a positive line limit for ``$rel``."; continue }
        $full = Join-Path $Worktree ($rel -replace '/', '\')
        if (-not (Test-Path $full)) { continue }
        $lines = 0
        try { $lines = @(Get-Content -Path $full -Encoding utf8 -ErrorAction Stop).Count } catch { $fails += "Validation environment: could not read ``$rel`` for its line budget: $($_.Exception.Message)"; continue }
        if ($lines -gt $max) {
            $touched = (@($Changed | Where-Object { $_ -eq $rel }).Count -gt 0)
            $fails += "``$rel`` has $lines lines; its budget is $max (``$budgetRel``).$(if ($touched) { ' This change grew it.' }) Put new behaviour in a new module or an existing extension point instead of growing this file. If the design genuinely requires a bigger file, raise the budget in the same change together with a decision record under ``$decisionsRel/``."
        }
    }
    return $fails
}

function Get-MechanicalFailures([string]$Worktree) {
    $fails = @()
    if (-not (Test-Path -LiteralPath $Worktree -PathType Container)) { return @('Validation environment: task checkout is missing or is not a directory; mechanical validation could not run.') }
    $pushed = $false
    try {
        Push-Location -LiteralPath $Worktree -ErrorAction Stop
        $pushed = $true
        & git fetch origin main --quiet 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not fetch origin/main for mechanical validation.' }
        $changed = @(& git diff --name-only origin/main...HEAD 2>$null | ForEach-Object { [string]$_ })
        if ($LASTEXITCODE -ne 0) { throw 'Could not determine changed files for mechanical validation.' }
        $forbidden = @($changed | Where-Object { Test-PathUnderForbidden -Path $_ -Forbidden $script:OwnershipRules.protectedPaths })
        if ($forbidden.Count -gt 0) {
            $fails += "The change touches paths that are off-limits for every task: $($forbidden -join ', ')."
        }
        $ws = @(& git diff --check origin/main...HEAD 2>&1 | ForEach-Object { [string]$_ } | Where-Object { $_ -ne "" })
        if ($LASTEXITCODE -ne 0 -and $ws.Count -eq 0) { throw 'Git whitespace validation failed without a diagnostic.' }
        if ($ws.Count -gt 0) {
            $fails += "``git diff --check`` reports whitespace errors:`n$((($ws | Select-Object -First 8) -join "`n"))"
        }
        foreach ($f in @($changed | Where-Object { $_ -match '\.ps1$' })) {
            if (-not (Test-Path $f)) { continue }
            $errs = $null
            [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f).Path, [ref]$null, [ref]$errs) | Out-Null
            if ($errs -and $errs.Count -gt 0) {
                $detail = @($errs | Select-Object -First 3 | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join "`n"
                $fails += "``$f`` does not parse under Windows PowerShell 5.1 ($($errs.Count) error(s)):`n$detail"
            }
        }
        # File budgets (ownership.budgetsFile, inert when the file does not exist): a JSON map from a
        # file to the maximum number of lines it may have. A budget is a hard rule authors cannot
        # argue with; raising one is a design decision, so the same change must add or amend a
        # decision record.
        $fails += @(Get-BudgetFailures $Worktree $changed)
        # The project's test command, when the change touches what it covers. Run here rather than
        # at push time so a red test is fed back to the author with its output instead of failing
        # the task.
        if ($TestCommand -and ((-not $TestGateWhenChanged) -or @($changed | Where-Object { $_ -match $TestGateWhenChanged }).Count -gt 0)) {
            $fails += @(Get-TestGateFailures $Worktree)
        }
    } catch {
        Write-Log "Mechanical checks could not be completed in ${Worktree}: $($_.Exception.Message)"
        $fails += "Validation environment: mechanical validation could not be completed: $($_.Exception.Message)"
    } finally { if ($pushed) { Pop-Location } }
    return $fails
}

# ----------------------------------------------------------------------------- acceptance commands
# A task may carry a fenced block under "## Acceptance commands": one runnable command per line.
# The supervisor executes them itself, on the host, in the worktree, before any reviewer is asked,
# and hands the transcript to both agents. Neither agent can produce this evidence on its own:
# the implementer's sandbox refuses to launch powershell.exe at all, and the reviewer's read-only
# sandbox denies the temp writes most tests need. So a test that passes 21/21 on this machine
# read as "unverified" to one agent and as seven failures to the other, and one task spent eleven
# review rounds on a fact the host establishes in under a second.
function Get-AcceptanceCommands([string]$Body) {
    if ([string]::IsNullOrWhiteSpace($Body)) { return @() }
    $m = [regex]::Match($Body, '(?ms)^##\s*Acceptance commands\s*\r?\n\s*```[^\r\n]*\r?\n(.*?)\r?\n\s*```')
    if (-not $m.Success) { return @() }
    return @($m.Groups[1].Value -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}

# The planner sometimes writes a check as `powershell -NoProfile -Command "<text>"`. Written that
# way it only works from cmd.exe: as a PowerShell line, the double-quoted string expands every
# `$name` before the inner shell sees it (`"$c = Get-Content"` reaches it as `" = Get-Content"`),
# so the check fails on every run whatever the change contains. The intent is unambiguous --
# "run <text> in a fresh PowerShell" -- and every acceptance line already runs in a fresh
# `powershell -NoProfile`, so the line is unwrapped and <text> is executed directly as code.
# The check is then really executed, with its intended meaning, and no revision round is spent
# on a defect of the task body. Left as written, one such line cost a task all six revision
# rounds, with the author "fixing" code that was never the problem.
function Resolve-AcceptanceCommand([string]$Command) {
    $result = [pscustomobject]@{ Command = $Command; Rewritten = $false; Original = $Command }
    if ([string]::IsNullOrWhiteSpace($Command)) { return $result }
    $m = [regex]::Match($Command, '(?i)^\s*powershell(?:\.exe)?(?:\s+-(?!c\b|co\b|com\b|comm\b|comma\b|comman\b|command\b)\w+(?:\s+(?!-)[^\s"]+)?)*\s+-(?:c|co|com|comm|comma|comman|command)\s+"(?<inner>.*)"\s*$')
    if (-not $m.Success) { return $result }
    $inner = $m.Groups["inner"].Value.Replace('\"', '"').Trim()
    if (-not $inner) { return $result }
    $result.Command = $inner
    $result.Rewritten = $true
    return $result
}

# A nested `powershell -Command` that Resolve-AcceptanceCommand could not unwrap (arguments
# after the closing quote, single quotes, a quote that does not close) and whose quoted text
# contains `$` is still a line that can never pass; report it as a defect of the task body
# instead of charging the author a revision for it.
function Get-AcceptanceCommandDefect([string]$Command) {
    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
    if ((Resolve-AcceptanceCommand $Command).Rewritten) { return $null }
    if ($Command -match '(?i)\bpowershell(\.exe)?\b[^|;]*\s-(c|co|com|comm|comma|comman|command)\s+"[^"]*\$') {
        return 'it is a nested `powershell -Command "..."` whose double-quoted text contains `$` and which the supervisor could not unwrap; as a PowerShell line every `$name` inside the quotes expands to an empty string before the inner shell parses it, so it can never pass. Put the check in a script and call it with `powershell -NoProfile -File ...`, or write it as a plain expression on the line itself'
    }
    return $null
}

function Invoke-AcceptanceCommands([string]$Worktree, [string[]]$Commands, [int]$TimeoutSeconds = $AcceptanceTimeoutSeconds, [string]$SkipReason = "") {
    $results = @()
    if (-not $Commands -or $Commands.Count -eq 0) { return $results }
    if ($TimeoutSeconds -le 0) { $TimeoutSeconds = 300 }
    # Commands from an issue whose authors are not trusted (see Test-AcceptanceAuthority) are
    # never executed. They count as passed, so no revision is spent on them, and the transcript
    # says plainly that the reviewer must judge those checks by reading.
    if ($SkipReason) {
        foreach ($cmd in $Commands) {
            $results += [pscustomobject]@{ Command = $cmd; ExitCode = 0; Output = "NOT RUN: $SkipReason. The reviewer must judge the check this line stands for from the diff."; Ok = $true; Seconds = 0; Skipped = $true; SkipLabel = "NOT RUN (untrusted author)" }
        }
        return $results
    }
    # These lines were written by an agent into an issue body. They run one at a time, inside the
    # worktree, under a timeout, and a short list of shapes that could reach outside the worktree
    # or the machine is refused outright rather than executed.
    $refuse = '(?i)(Remove-Item\s+.*-Recurse|\brm\s+-rf|rmdir\s+/s|del\s+/s|\bformat\b|shutdown|Restart-Computer|Stop-Computer|reg\s+delete|git\s+push|git\s+reset\s+--hard|git\s+clean|Set-ExecutionPolicy|Invoke-WebRequest|\biwr\b|\bcurl\b|\bwget\b|Start-BitsTransfer)'
    $i = 0
    foreach ($cmd in $Commands) {
        $i++
        try { Write-Live -Tag "acceptance-$i" -Provider "" -StartedAtUtc (Get-Date).ToUniversalTime() -Deadline "" -Role "supervisor" -Step "supervisor acceptance checks" -Summary "running acceptance command $i/$($Commands.Count): $cmd" } catch { Write-Log "[acceptance-$i] Write-Live failed: $($_.Exception.Message)" }
        $resolved = Resolve-AcceptanceCommand $cmd
        if ($resolved.Rewritten) {
            Write-Log "acceptance command $i unwrapped from nested powershell -Command and run as code: $($resolved.Command)"
            $cmd = $resolved.Command
        }
        $defect = Get-AcceptanceCommandDefect $cmd
        if ($defect) {
            # Not a failure of the change: counted as passed so no revision is spent on it, and
            # said plainly in the transcript so the reviewer judges that check by reading.
            Write-Log "acceptance command $i not run, task-body defect: $cmd"
            $results += [pscustomobject]@{ Command = $cmd; ExitCode = 0; Output = "NOT RUN: this line is a defect of the task body, not of the change -- $defect. The reviewer must judge the check this line stood for from the diff; the task body should be corrected."; Ok = $true; Seconds = 0; Skipped = $true; SkipLabel = "NOT RUN (task-body defect)" }
            continue
        }
        if ($cmd -match $refuse) {
            $results += [pscustomobject]@{ Command = $cmd; ExitCode = -1; Output = "refused: this command matches a pattern the supervisor will not run from an issue body"; Ok = $false; Seconds = 0; Skipped = $false }
            continue
        }
        $outFile = Join-Path $statePath "acceptance-$i.out.txt"
        $errFile = Join-Path $statePath "acceptance-$i.err.txt"
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
        # Wrapped so the child's exit code is meaningful whether the command is native (git,
        # powershell -File) or a cmdlet expression, and encoded so no quoting inside the command
        # is ever re-interpreted by a second command-line parser.
        $wrapped = "`$ErrorActionPreference = 'Stop'; `$ok = `$true; try { & { $cmd }; `$ok = `$? } catch { `$_ | Out-String | Write-Output; `$ok = `$false }; if (`$LASTEXITCODE) { exit `$LASTEXITCODE } elseif (-not `$ok) { exit 1 } else { exit 0 }"
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($wrapped))
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $code = -3
        try {
            # System.Diagnostics.Process directly rather than Start-Process -PassThru: the
            # latter's object can report a null ExitCode after a timed WaitForExit, which would
            # turn every pass into a failure. Output is pumped to files by the process itself.
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "powershell.exe"
            $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand $encoded"
            $psi.WorkingDirectory = $Worktree
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $outTask = $p.StandardOutput.ReadToEndAsync()
            $errTask = $p.StandardError.ReadToEndAsync()
            if ($p.WaitForExit($TimeoutSeconds * 1000)) {
                $p.WaitForExit()   # flushes the async stream readers before ExitCode is read
                $code = $p.ExitCode
            } else {
                & taskkill /T /F /PID $p.Id 2>&1 | Out-Null
                $code = -2
            }
            [System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), 5000) | Out-Null
            if ($outTask.IsCompleted) { Write-Utf8File $outFile ([string]$outTask.Result) }
            if ($errTask.IsCompleted) { Write-Utf8File $errFile ([string]$errTask.Result) }
        } catch { $code = -3 }
        $sw.Stop()
        $text = ""
        if (Test-Path $outFile) { $text += [string](Get-Content -Raw $outFile -ErrorAction SilentlyContinue) }
        if (Test-Path $errFile) {
            $e = [string](Get-Content -Raw $errFile -ErrorAction SilentlyContinue)
            # powershell.exe serialises progress records to stderr as CLIXML; that is noise.
            $e = (($e -split "\r?\n") | Where-Object { $_ -notmatch '^\s*(#< CLIXML|<Objs )' }) -join "`n"
            if ($e -and $e.Trim()) { $text += "`n[stderr]`n" + $e }
        }
        if ($code -eq -2) { $text += "`n[timed out after $TimeoutSeconds s and was killed]" }
        if ($code -eq -3) { $text += "`n[could not be started]" }
        $text = $text.Trim()
        if ($text.Length -gt 3000) { $text = $text.Substring(0, 1500) + "`n...[" + ($text.Length - 3000) + " chars omitted]...`n" + $text.Substring($text.Length - 1500) }
        $results += [pscustomobject]@{ Command = $(if ($resolved.Rewritten) { "$cmd   (unwrapped by the supervisor from: $($resolved.Original))" } else { $cmd }); ExitCode = $code; Output = $text; Ok = ($code -eq 0); Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
    }
    return $results
}

function Format-AcceptanceReport([object[]]$Results, [string]$Worktree) {
    if (-not $Results -or $Results.Count -eq 0) { return "" }
    $lines = @("These commands were executed by the supervisor on the host machine, inside the worktree, after the author finished. This transcript is authoritative for the checks it covers; it is not the author's claim.", "")
    foreach ($r in $Results) {
        $mark = if ($r.Skipped) { $(if ($r.PSObject.Properties['SkipLabel'] -and $r.SkipLabel) { $r.SkipLabel } else { "NOT RUN" }) } elseif ($r.Ok) { "PASS" } else { "FAIL" }
        $lines += "### ${mark}: ``$($r.Command)``  (exit $($r.ExitCode), $($r.Seconds)s)"
        $lines += '```'
        $lines += $(if ($r.Output) { $r.Output } else { "(no output)" })
        $lines += '```'
        $lines += ""
    }
    return ($lines -join "`n")
}

# ----------------------------------------------------------------------------- trusted authors
# Who wrote (and last edited) an issue body, from GitHub's GraphQL API. Returns
# @{ Author; Editor } (Editor is "" for a body never edited), or $null when the lookup failed --
# callers treat $null as untrusted. Cached per cycle: the same objective is looked up once.
function Get-IssueIdentity([int]$Number) {
    if (-not $script:identityCache) { $script:identityCache = @{} }
    if ($script:identityCache.ContainsKey($Number)) { return $script:identityCache[$Number] }
    $owner, $name = $Repository.Split('/', 2)
    $query = 'query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){issue(number:$number){author{login} editor{login}}}}'
    $rows = @(Invoke-GhJson @("api", "graphql", "-f", "query=$query", "-f", "owner=$owner", "-f", "name=$name", "-F", "number=$Number"))
    $identity = $null
    if ($rows.Count -gt 0 -and $rows[0].data -and $rows[0].data.repository -and $rows[0].data.repository.issue) {
        $issue = $rows[0].data.repository.issue
        $identity = [pscustomobject]@{
            Author = if ($issue.author) { [string]$issue.author.login } else { "" }
            Editor = if ($issue.editor) { [string]$issue.editor.login } else { "" }
        }
    }
    $script:identityCache[$Number] = $identity
    return $identity
}

# Whether the acceptance commands of $Issue may run on the host (see lib/trusted-authors.ps1).
# Always trusted when no allowlist is configured.
function Get-AcceptanceAuthority([object]$Issue) {
    if (@($TrustedAuthors).Count -eq 0) { return [pscustomobject]@{ Trusted = $true; Reason = "" } }
    $task = Get-IssueIdentity ([int]$Issue.number)
    $objRefs = @(Get-IssueRefs (Get-Field ([string]$Issue.body) "Objective"))
    $objective = $null
    if ($objRefs.Count -gt 0 -and $task -and $script:selfLogin -and ([string]$task.Author).ToLowerInvariant() -eq $script:selfLogin.ToLowerInvariant()) {
        $objective = Get-IssueIdentity ([int]$objRefs[0])
    }
    $actors = @(Get-AcceptanceActors -Task $task -Objective $objective -SelfLogin $script:selfLogin -HasObjective ($objRefs.Count -gt 0))
    return (Test-AcceptanceAuthority -TrustedAuthors $TrustedAuthors -SelfLogin $script:selfLogin -Actors $actors)
}

# The owner's dashboard: everything status.json says plus the queue by state, the last 24 h of
# agent sessions (provider, duration, codex's own "tokens used" figure), review rounds and
# merges, and providers' pause reasons. Written every cycle from data the loop already holds,
# plus three cheap label queries and one pass over the supervisor log and the codex run logs.
# Served by scripts/serve-dashboard.ps1; the page itself is docs/dashboard/index.html. Never
# load-bearing: a failure here is swallowed.
function Get-CodexTokensFromLog([string]$LogFile) {
    try {
        $raw = Get-Content -Raw -Path $LogFile -Encoding utf8
        $lines = @($raw -split '\r?\n')
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ([string]::IsNullOrWhiteSpace($lines[$i])) { continue }
            $obj = $null
            try { $obj = $lines[$i] | ConvertFrom-Json } catch { continue }
            if (-not $obj) { continue }

            $info = $null
            if ($obj.type -eq 'token_count') { $info = $obj.info }
            elseif ($obj.payload -and $obj.payload.type -eq 'token_count') { $info = $obj.payload.info }
            if ($null -eq $info -or $null -eq $info.total_token_usage) { continue }

            try {
                $usage = $info.total_token_usage
                if ($null -eq $usage.input -or $null -eq $usage.cached_input -or $null -eq $usage.output) { break }
                return ([int64]$usage.input + [int64]$usage.cached_input + [int64]$usage.output)
            } catch { break }
        }

        # Keep the pre-existing plain-text fallback byte-for-byte behaviorally identical.
        $m = [regex]::Match($raw, '(?m)^tokens used\s*\r?\n\s*([\d.,]+)')
        if ($m.Success) { $n = ($m.Groups[1].Value -replace '[^\d]', ''); if ($n) { return [int64]$n } }
    } catch { }
    return $null
}

function Get-RecentSessions([datetime]$Since, [string[]]$LogLines = $null) {
    $sessions = @{}
    $latestByTag = @{}
    if ($null -eq $LogLines) {
        if (-not (Test-Path $logPath)) { return @() }
        $LogLines = @(Get-Content -Path $logPath -Encoding utf8 -Tail 12000)
    }
    $lines = $LogLines
    foreach ($line in $lines) {
        if ($line -match '^(\S+) \[([^\]]+)\] launching (claude|codex|copilot) \((edit|readonly)\) in ([^,]+), timeout') {
            $t = $null; try { $t = [datetime]::Parse($Matches[1], $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { continue }
            if ($t -lt $Since) { continue }
            $tag = $Matches[2]
            $runId = "$tag@$($t.ToUniversalTime().Ticks)"
            $latestByTag[$tag] = $runId
            $sessions[$runId] = @{ runId = $runId; tag = $tag; provider = $Matches[3]; mode = $Matches[4]; startedAt = $t.ToString("o"); finishedAt = $null; seconds = $null; exit = $null; outcome = "running"; tokens = $null; tokensCacheRead = $null; workDir = $Matches[5] }
        } elseif ($line -match '^(\S+) \[([^\]]+)\] (claude|codex|copilot) finished with exit (-?\d+)') {
            if ($latestByTag.ContainsKey($Matches[2])) {
                $t = $null; try { $t = [datetime]::Parse($Matches[1], $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { }
                $ss = $sessions[$latestByTag[$Matches[2]]]
                $ss.finishedAt = if ($t) { $t.ToString("o") } else { $null }
                $ss.exit = [int]$Matches[4]
                $ss.outcome = if ($ss.exit -eq 0) { "ok" } else { "exit $($ss.exit)" }
                if ($t) { try { $ss.seconds = [int]($t - [datetime]::Parse($ss.startedAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)).TotalSeconds } catch { } }
            }
        } elseif ($line -match '^(\S+) \[([^\]]+)\] (claude|codex|copilot) is out of quota') {
            if ($latestByTag.ContainsKey($Matches[2])) { $sessions[$latestByTag[$Matches[2]]].outcome = "quota"; $sessions[$latestByTag[$Matches[2]]].finishedAt = $Matches[1] }
        } elseif ($line -match '^(\S+) \[([^\]]+)\] timed out') {
            if ($latestByTag.ContainsKey($Matches[2])) { $sessions[$latestByTag[$Matches[2]]].outcome = "timeout"; $sessions[$latestByTag[$Matches[2]]].finishedAt = $Matches[1] }
        }
    }
    # A finished session's tokens never change again, so once computed they are cached on disk
    # (keyed by tag) and reused on every later cycle instead of re-reading the codex log / claude
    # jsonl transcripts / copilot usage file for it. A session still "running" is never read from
    # or written to the cache -- it has no final figure yet, so it is recomputed every call, same
    # as before this cache existed.
    $cachePath = Join-Path $statePath "sessions.json"
    $cache = @{}
    try {
        if (Test-Path $cachePath) {
            $raw = Get-Content -Raw -Path $cachePath -Encoding utf8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $parsedCache = $raw | ConvertFrom-Json
                foreach ($prop in $parsedCache.PSObject.Properties) {
                    $cache[$prop.Name] = @{ provider = [string]$prop.Value.provider; tokens = [int64]$prop.Value.tokens; tokensCacheRead = $(if ($null -ne $prop.Value.tokensCacheRead) { [int64]$prop.Value.tokensCacheRead } else { $null }); finishedAt = [string]$prop.Value.finishedAt }
                }
            }
        }
    } catch { $cache = @{} }
    $cacheDirty = $false

    # Prune anything that fell out of the 24h window this call is looking at before using the
    # cache for hits, so a cycle made up entirely of cache hits (or no new entries at all) still
    # drops stale entries instead of keeping sessions.json growing without bound.
    foreach ($t in @($cache.Keys)) {
        $finishedAtDate = [datetime]::MinValue
        $parsedOk = [datetime]::TryParse([string]$cache[$t].finishedAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$finishedAtDate)
        if (-not $parsedOk -or $finishedAtDate -lt $Since) { $cache.Remove($t); $cacheDirty = $true }
    }

    foreach ($runId in @($sessions.Keys)) {
        $ss = $sessions[$runId]
        $tag = $ss.tag
        if ($ss.finishedAt -and $null -eq $ss.seconds) {
            $ss.seconds = [int](([datetime]$ss.finishedAt) - ([datetime]$ss.startedAt)).TotalSeconds
        }
        # Legacy cache entries are usable only for the exact provider and completion time.
        $cacheKey = if ($cache.ContainsKey($runId)) { $runId } else { $tag }
        if ($ss.outcome -ne "running" -and $cache.ContainsKey($cacheKey) -and
            $cache[$cacheKey].provider -eq $ss.provider -and $cache[$cacheKey].finishedAt -eq $ss.finishedAt) {
            $ss.tokens = $cache[$cacheKey].tokens
            $ss.tokensCacheRead = $cache[$cacheKey].tokensCacheRead
            continue
        }
        # Old runs shared filenames. Never attribute the newest file to an older run.
        if ($ss.provider -ne "claude" -and $latestByTag[$tag] -ne $runId) { continue }
        if ($ss.provider -eq "codex") {
            $logFile = Join-Path $statePath "$tag.output.md.log"
            if (-not (Test-Path $logFile)) { continue }
            try {
                $codexTokens = Get-CodexTokensFromLog $logFile
                if ($null -ne $codexTokens) { $ss.tokens = $codexTokens }
            } catch { }
        } elseif ($ss.provider -eq "claude" -and $ss.workDir) {
            $from = $null; try { $from = [datetime]::Parse($ss.startedAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { continue }
            $to = if ($ss.finishedAt) { try { [datetime]::Parse($ss.finishedAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { Get-Date } } else { Get-Date }
            $usage = Get-ClaudeJsonlUsage $ss.workDir $from $to
            if ($usage.total -gt 0) { $ss.tokens = $usage.total; $ss.tokensCacheRead = $usage.cacheRead }
        } elseif ($ss.provider -eq "copilot") {
            # Copilot CLI writes its own usage report (--usage-output-file) next to the output:
            # tokenDetails.{input,cache_read,cache_write,output}.tokenCount, plus the number of
            # premium requests the session cost, which is the unit Copilot plans are metered in.
            $usageFile = Join-Path $statePath "$tag.output.md.usage.json"
            if (-not (Test-Path $usageFile)) { continue }
            try {
                $u = Get-Content -Raw -Path $usageFile -Encoding utf8 | ConvertFrom-Json
                $sum = [int64]0
                if ($u.tokenDetails) { foreach ($k in @("input", "cache_read", "cache_write", "output")) { $d = $u.tokenDetails.$k; if ($d -and $d.tokenCount) { $sum += [int64]$d.tokenCount } } }
                if ($sum -gt 0) { $ss.tokens = $sum }
                if ($null -ne $u.totalPremiumRequestCost) { $ss.premiumRequests = [double]$u.totalPremiumRequestCost }
            } catch { }
        }

        if ($ss.outcome -ne "running" -and $null -ne $ss.tokens) {
            $cache[$runId] = @{ provider = $ss.provider; tokens = $ss.tokens; tokensCacheRead = $ss.tokensCacheRead; finishedAt = $ss.finishedAt }
            $cacheDirty = $true
        }
    }

    if ($cacheDirty) {
        try {
            $toWrite = [ordered]@{}
            foreach ($t in $cache.Keys) { $toWrite[$t] = $cache[$t] }
            Write-Utf8File $cachePath ([pscustomobject]$toWrite | ConvertTo-Json -Depth 8)
        } catch { }
    }

    return @($sessions.Values | ForEach-Object { [pscustomobject]$_ } | Sort-Object -Property startedAt -Descending)
}

# Claude Code writes a JSONL transcript per session under ~/.claude/projects/<slugified-cwd>/,
# even for the non-interactive `claude -p` runs this supervisor launches -- one line per
# assistant turn, each carrying a real "usage" object (input/output/cache tokens) straight from
# the API response. That's the only source of real Claude token counts we have; unlike Codex,
# Claude Code prints nothing usable to stdout in non-interactive mode. The project directory name
# is the work dir with every ':' and '\' replaced by '-' (Claude Code's own slugging scheme).
function Get-ClaudeJsonlTokens([string]$WorkDir, [datetime]$From, [datetime]$To) {
    return (Get-ClaudeJsonlUsage $WorkDir $From $To).total
}

# Same source, split the way the owner reads it: "new" tokens (input + output + cache writes)
# are what the session actually sent and generated; "cacheRead" is the cached context re-read
# on every turn, which is why a 15-minute session can show tens of millions of tokens. Both are
# real API usage, but only the split makes the figures comparable between sessions and providers.
function Get-ClaudeJsonlUsage([string]$WorkDir, [datetime]$From, [datetime]$To) {
    $slug = ($WorkDir -replace '[:\\]', '-')
    $dir = Join-Path $env:USERPROFILE ".claude\projects\$slug"
    $cacheRead = [int64]0
    if (-not (Test-Path $dir)) { return @{ total = [int64]0; cacheRead = [int64]0 } }
    # The JSONL "timestamp" field is always UTC ("...Z"); $From/$To come in as Local (parsed from
    # this script's own ISO-with-offset strings). DateTime comparison ignores Kind and compares
    # raw ticks, so mixing Local and Utc values here silently compares the wrong instants -- both
    # sides must be normalised to UTC first.
    $fromUtc = $From.ToUniversalTime()
    $toUtc = $To.ToUniversalTime()
    $total = 0
    Get-ChildItem -Path $dir -Filter "*.jsonl" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $From.AddMinutes(-5) } | ForEach-Object {
        try {
            foreach ($line in (Get-Content -Path $_.FullName -Encoding utf8 -ErrorAction Stop)) {
                if ($line -notmatch '"usage"') { continue }
                $obj = $null; try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                if (-not $obj.timestamp) { continue }
                $t = $null; try { $t = [datetime]::Parse($obj.timestamp, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { continue }
                $tUtc = $t.ToUniversalTime()
                if ($tUtc -lt $fromUtc -or $tUtc -gt $toUtc.AddSeconds(5)) { continue }
                $u = $obj.message.usage
                if (-not $u) { continue }
                $total += [int64]($u.input_tokens) + [int64]($u.output_tokens) + [int64]($u.cache_creation_input_tokens) + [int64]($u.cache_read_input_tokens)
                $cacheRead += [int64]($u.cache_read_input_tokens)
            }
        } catch { }
    }
    return @{ total = [int64]$total; cacheRead = $cacheRead }
}

# Reads the plan label Claude Code itself stored after login -- no network call, just the same
# local file the CLI already wrote. subscriptionType is e.g. "pro"/"max"; rateLimitTier is
# Anthropic's internal bucket name. Never reads or returns the access/refresh tokens themselves.
function Get-ClaudePlanLabel {
    $f = Join-Path $env:USERPROFILE ".claude\.credentials.json"
    if (-not (Test-Path $f)) { return $null }
    try {
        $j = Get-Content -Raw -Path $f -Encoding utf8 | ConvertFrom-Json
        if ($j.claudeAiOauth.subscriptionType) { return [string]$j.claudeAiOauth.subscriptionType }
    } catch { }
    return $null
}

# Pure translation of Anthropic's GET /api/oauth/usage response body into the same
# label/usedPercent/remaining/total/resetsAt/source shape Get-CodexQuota and
# ConvertFrom-CopilotUserResponse already produce. five_hour and seven_day are read
# independently -- either one missing (or missing its .utilization) simply drops that
# entry from the result instead of failing the other, so the result is always 0, 1 or 2
# items. resets_at is normalized to an ISO-8601 string whether the API sent Unix seconds
# (a JSON number, deserialized by ConvertFrom-Json as a numeric type) or an already-ISO
# string. Wrapped end-to-end in try/catch: never throws, even given $null or a
# completely unrelated object.
function ConvertFrom-ClaudeUsageResponse([object]$Response) {
    $quotas = @()
    try {
        if (-not $Response) { return $quotas }
        $windows = @(
            @{ prop = 'five_hour'; label = '5 h' },
            @{ prop = 'seven_day'; label = '7 d' }
        )
        foreach ($w in $windows) {
            $window = $Response.($w.prop)
            if ($null -eq $window -or $null -eq $window.utilization) { continue }
            $utilization = [double]$window.utilization
            $resetsAt = $null
            $resetRaw = $window.resets_at
            if ($null -ne $resetRaw) {
                if ($resetRaw -is [string]) {
                    $parsedDate = [datetime]::MinValue
                    if ([datetime]::TryParse($resetRaw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsedDate)) {
                        $resetsAt = $parsedDate.ToString('o')
                    } else {
                        $resetsAt = $resetRaw
                    }
                } else {
                    $resetsAt = [DateTimeOffset]::FromUnixTimeSeconds([int64]$resetRaw).UtcDateTime.ToString('o')
                }
            }
            $quotas += @{
                label       = $w.label
                usedPercent = $utilization
                remaining   = [math]::Round(100 - $utilization, 1)
                total       = 100
                resetsAt    = $resetsAt
                source      = 'claude-oauth-usage'
            }
        }
    } catch { }
    return $quotas
}

# Wraps ConvertFrom-ClaudeUsageResponse with the live /oauth/usage call and a cache, the same
# way Get-CopilotQuota wraps ConvertFrom-CopilotUserResponse. Unlike the Copilot cache, a
# backoffUntil field also survives a 429 so a rate-limited account stops asking for a full 30
# minutes instead of retrying every cycle. Cache age (not a timer) is the source of truth, so
# it survives supervisor restarts. Reads the OAuth access token out of .credentials.json only
# long enough to put it in the Authorization header of a single outbound request -- it is never
# written to the cache file, logged, or returned, and neither is the raw response body; only the
# two derived percentages and reset times (via ConvertFrom-ClaudeUsageResponse) leave this
# function. Wrapped so failures (missing CLI, missing credentials, network error, unexpected
# response shape) all fall back to returning an array -- the last cached quotas where that is
# meaningful (a 429, or the cache itself deciding not to call out), or @() -- and never throw
# into the dashboard-writing cycle.
function Get-ClaudeQuota {
    $cachePath = Join-Path $statePath "claude-quota-cache.json"
    $lastGood = @()
    $lastFetchedAt = $null
    try {
        if (Test-Path $cachePath) {
            $raw = Get-Content -Raw -Path $cachePath -Encoding utf8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $cached = $raw | ConvertFrom-Json
                $lastGood = @($cached.quotas)
                $lastFetchedAt = [string]$cached.fetchedAt

                $backoffUntilDate = [datetime]::MinValue
                if ($cached.backoffUntil -and [datetime]::TryParse([string]$cached.backoffUntil, $null, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$backoffUntilDate) -and $backoffUntilDate -gt (Get-Date)) {
                    return $lastGood
                }

                $fetchedAtDate = [datetime]::MinValue
                if ($lastFetchedAt -and [datetime]::TryParse($lastFetchedAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$fetchedAtDate) -and ((Get-Date) - $fetchedAtDate).TotalMinutes -lt 5) {
                    return $lastGood
                }
            }
        }
    } catch { }

    $credFile = Join-Path $env:USERPROFILE ".claude\.credentials.json"
    $accessToken = $null
    try {
        if (Test-Path $credFile) {
            $creds = Get-Content -Raw -Path $credFile -Encoding utf8 | ConvertFrom-Json
            if ($creds.claudeAiOauth.accessToken) { $accessToken = [string]$creds.claudeAiOauth.accessToken }
        }
    } catch { }
    if (-not $accessToken) { return @() }

    $version = "unknown"
    try {
        $verOut = (& claude --version) 2>$null
        if ($verOut -match '(\d+\.\d+\.\d+)') { $version = $Matches[1] }
    } catch { }

    try {
        $response = Invoke-RestMethod -Uri "https://api.anthropic.com/api/oauth/usage" -Method Get -Headers @{
            Authorization    = "Bearer $accessToken"
            "anthropic-beta" = "oauth-2025-04-20"
            "User-Agent"     = "claude-code/$version"
        } -ErrorAction Stop
    } catch {
        $statusCode = $null
        try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
        if ($statusCode -eq 429) {
            $toCache = [pscustomobject]@{ fetchedAt = $lastFetchedAt; quotas = $lastGood; backoffUntil = (Get-Date).AddMinutes(30).ToString("o") }
            try { Write-Utf8File $cachePath ($toCache | ConvertTo-Json -Depth 8) } catch { }
            return $lastGood
        }
        Write-Log "Claude usage endpoint: unexpected response shape"
        return @()
    }

    if (-not $response -or -not $response.five_hour -or -not $response.seven_day -or $null -eq $response.five_hour.utilization -or $null -eq $response.seven_day.utilization) {
        Write-Log "Claude usage endpoint: unexpected response shape"
        return @()
    }

    $parsed = ConvertFrom-ClaudeUsageResponse $response
    $toCache = [pscustomobject]@{ fetchedAt = (Get-Date).ToString("o"); quotas = $parsed; backoffUntil = $null }
    try { Write-Utf8File $cachePath ($toCache | ConvertTo-Json -Depth 8) } catch { }
    return $parsed
}

# Codex CLI writes a JSONL transcript per session under ~/.codex/sessions/ (recursive, dated
# subfolders). Each event line whose payload is a "token_count" carries a rate_limits object
# straight from the Codex backend, including the 5h ("primary") and 7-day ("secondary") usage
# windows this reads. Unlike Get-ClaudeJsonlTokens, this never enumerates the whole tree --
# only the 5 most-recently-modified files are opened, so this stays fast even on a host with
# years of Codex session history. Wrapped end-to-end in try/catch: any failure (missing
# directory, unreadable file, malformed JSON, no matching event) yields the same empty result
# rather than ever throwing into the dashboard-writing cycle.
function Get-CodexQuota([string]$SessionsRoot = (Join-Path $env:USERPROFILE ".codex\sessions")) {
    try {
        if (-not (Test-Path $SessionsRoot)) { return [pscustomobject]@{ plan = $null; quotas = @() } }
        $files = Get-ChildItem -Path $SessionsRoot -Recurse -Filter "*.jsonl" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 5
        $bestEvent = $null
        $bestTime = [datetime]::MinValue
        foreach ($f in $files) {
            foreach ($line in (Get-Content -Path $f.FullName -Encoding utf8 -ErrorAction SilentlyContinue)) {
                if ($line -notmatch '"token_count"') { continue }
                $obj = $null; try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                if (-not $obj.payload -or $obj.payload.type -ne 'token_count') { continue }
                if (-not $obj.payload.rate_limits -or $obj.payload.rate_limits.limit_id -ne 'codex') { continue }
                if (-not $obj.timestamp) { continue }
                $t = $null; try { $t = [datetime]::Parse($obj.timestamp, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { continue }
                if ($t -gt $bestTime) { $bestTime = $t; $bestEvent = $obj }
            }
        }
        if (-not $bestEvent) { return [pscustomobject]@{ plan = $null; quotas = @() } }
        $rl = $bestEvent.payload.rate_limits
        $quotas = @()
        # Labels come from the window the server reports, not from position: on some plans the
        # "primary" window is not 5 h (a free login showed a ~30-day primary window). readAt is
        # the transcript timestamp the figures come from, so the page can tell a window that has
        # already reset (resetsAt in the past, no session since) from a live reading.
        $readAt = $bestTime.ToUniversalTime().ToString('o')
        $labelFor = { param($minutes) if (-not $minutes) { 'window' } elseif ($minutes -lt 1440) { "$([math]::Round($minutes / 60)) h" } else { "$([math]::Round($minutes / 1440)) d" } }
        if ($null -ne $rl.primary) {
            $quotas += @{
                label       = (& $labelFor $rl.primary.window_minutes)
                readAt      = $readAt
                usedPercent = $rl.primary.used_percent
                remaining   = [math]::Round(100 - $rl.primary.used_percent, 1)
                total       = 100
                resetsAt    = [DateTimeOffset]::FromUnixTimeSeconds([int64]$rl.primary.resets_at).UtcDateTime.ToString('o')
                source      = 'codex-jsonl'
            }
        }
        if ($null -ne $rl.secondary) {
            $quotas += @{
                label       = (& $labelFor $rl.secondary.window_minutes)
                readAt      = $readAt
                usedPercent = $rl.secondary.used_percent
                remaining   = [math]::Round(100 - $rl.secondary.used_percent, 1)
                total       = 100
                resetsAt    = [DateTimeOffset]::FromUnixTimeSeconds([int64]$rl.secondary.resets_at).UtcDateTime.ToString('o')
                source      = 'codex-jsonl'
            }
        }
        return [pscustomobject]@{ plan = [string]$rl.plan_type; quotas = $quotas }
    } catch {
        return [pscustomobject]@{ plan = $null; quotas = @() }
    }
}

# Which ChatGPT account a Codex login actually belongs to. `codex login` writes one auth.json per
# CODEX_HOME, and its id_token carries the account id and the plan OpenAI sold that account. Two
# CODEX_HOMEs can hold two logins of the SAME account: that looks like a reserve on the dashboard
# while both draw on one quota window, so the export publishes a short fingerprint of the account
# id -- never the id itself, never a token -- and the page compares the logins. The plan here is
# better than the transcript's: it is current even for a login that has not run a session since
# the owner changed subscription. Returns @{ accountId; plan; checkedAt }, all $null on any
# failure (missing file, malformed JSON, unexpected claim shape), never throwing into the cycle.
function Get-CodexAccountIdentity([string]$CodexHome = (Join-Path $env:USERPROFILE ".codex")) {
    $empty = [pscustomobject]@{ accountId = $null; plan = $null; checkedAt = $null }
    try {
        $authPath = Join-Path $CodexHome "auth.json"
        if (-not (Test-Path $authPath)) { return $empty }
        $auth = (Get-Content -Raw -Path $authPath -Encoding utf8 -ErrorAction Stop) | ConvertFrom-Json
        $idToken = if ($auth.tokens) { [string]$auth.tokens.id_token } else { "" }
        if (-not $idToken) { return $empty }
        $parts = $idToken.Split('.')
        if ($parts.Count -lt 2) { return $empty }
        # JWT payloads are base64url without padding; .NET needs '+', '/' and the '=' padding back.
        $b = $parts[1].Replace('-', '+').Replace('_', '/')
        while (($b.Length % 4) -ne 0) { $b += '=' }
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b)) | ConvertFrom-Json
        $a = $claims.'https://api.openai.com/auth'
        if (-not $a) { return $empty }
        $fingerprint = $null
        $rawId = [string]$a.chatgpt_account_id
        if ($rawId) {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($rawId))
                $fingerprint = (([BitConverter]::ToString($bytes)) -replace '-', '').Substring(0, 8)
            } finally { $sha.Dispose() }
        }
        return [pscustomobject]@{
            accountId = $fingerprint
            plan      = if ($a.chatgpt_plan_type) { [string]$a.chatgpt_plan_type } else { $null }
            checkedAt = if ($a.chatgpt_subscription_last_checked) { [string]$a.chatgpt_subscription_last_checked } else { $null }
        }
    } catch { return $empty }
}

# GitHub's copilot_internal/user endpoint (see `gh api copilot_internal/user`) reports the
# account's plan and a name-keyed quota_snapshots object -- chat, premium_interactions, and
# whatever other categories GitHub adds later. This iterates those properties generically
# rather than hardcoding names, so a new quota category shows up without a code change. An
# entitlement of 0 means the plan does not grant that quota at all (e.g. premium_interactions
# on a plan with no premium requests); such a snapshot has no meaningful usedPercent (division
# by zero) and is dropped from the list rather than reported as 0/0 -- premium_interactions
# specifically is instead surfaced via noPremiumRequests. quota_reset_date is read top-level
# first (one shared monthly reset for every category) and falls back to a per-snapshot field of
# the same name if a future response nests it there instead. Pure: no gh calls, no file I/O,
# and safe to call with $null or a malformed object.
function ConvertFrom-CopilotUserResponse([object]$Response) {
    $plan = $null
    $quotas = @()
    $noPremiumRequests = $false
    try {
        if ($Response -and $Response.copilot_plan) { $plan = [string]$Response.copilot_plan }
        $snapshots = $Response.quota_snapshots
        if ($snapshots) {
            $topResetRaw = $Response.quota_reset_date
            foreach ($prop in $snapshots.PSObject.Properties) {
                $snap = $prop.Value
                if ($null -eq $snap) { continue }
                $entitlement = $null
                try { $entitlement = [double]$snap.entitlement } catch { continue }
                if (-not $entitlement -or $entitlement -le 0) { continue }
                $remaining = 0
                try { $remaining = [double]$snap.remaining } catch { }
                $resetRaw = if ($topResetRaw) { $topResetRaw } else { $snap.quota_reset_date }
                $resetIso = $null
                if ($resetRaw) {
                    $parsedDate = [datetime]::MinValue
                    if ([datetime]::TryParse([string]$resetRaw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsedDate)) {
                        $resetIso = $parsedDate.ToString("o")
                    } else {
                        $resetIso = [string]$resetRaw
                    }
                }
                $label = if ($prop.Name.Length -gt 0) { $prop.Name.Substring(0, 1).ToUpperInvariant() + $prop.Name.Substring(1) } else { $prop.Name }
                $quotas += @{
                    label       = $label
                    usedPercent = [math]::Round(100 * ($entitlement - $remaining) / $entitlement, 1)
                    remaining   = $remaining
                    total       = $entitlement
                    resetsAt    = $resetIso
                    source      = 'copilot-gh-api'
                }
            }
            if ($snapshots.premium_interactions -and [double]$snapshots.premium_interactions.entitlement -eq 0) {
                $noPremiumRequests = $true
            }
        }
    } catch { }
    return [pscustomobject]@{ plan = $plan; quotas = $quotas; noPremiumRequests = $noPremiumRequests }
}

# Wraps ConvertFrom-CopilotUserResponse with the actual `gh` call and a cache, since GitHub's
# quota numbers do not change fast enough to justify a fresh call every ~120s poll cycle. The
# cache file's age (not a timer) is the source of truth, so it survives supervisor restarts the
# same way providers.json does. 110s -- just under the poll interval -- means a cycle that runs
# slightly early still reuses the previous cycle's call instead of doubling up. $statePath and
# $script:gh are read via lexical scope, the same way Load-State/Save-State and Invoke-Gh read
# them, rather than as parameters. Wrapped end-to-end in try/catch like Get-CodexQuota: any
# failure (missing/unauthenticated `gh`, a network error, malformed JSON, an unwritable cache
# file) falls back to the last good cache if one exists, or the same empty result Get-CodexQuota
# returns, and never throws into the dashboard-writing cycle.
function Get-CopilotQuota {
    $cachePath = Join-Path $statePath "copilot-quota-cache.json"
    $lastGood = $null
    try {
        if (Test-Path $cachePath) {
            $raw = Get-Content -Raw -Path $cachePath -Encoding utf8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $cached = $raw | ConvertFrom-Json
                $lastGood = @{ plan = $cached.plan; quotas = @($cached.quotas); noPremiumRequests = [bool]$cached.noPremiumRequests }
                $fetchedAt = [datetime]::MinValue
                if ([datetime]::TryParse([string]$cached.fetchedAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$fetchedAt) -and ((Get-Date) - $fetchedAt).TotalSeconds -lt 110) {
                    return $lastGood
                }
            }
        }
    } catch { }
    try {
        $rows = Invoke-GhJson @("api", "copilot_internal/user")
        if ($rows.Count -eq 0) { throw "gh api copilot_internal/user returned no data" }
        $parsed = ConvertFrom-CopilotUserResponse $rows[0]
        $toCache = [pscustomobject]@{
            fetchedAt         = (Get-Date).ToString("o")
            plan              = $parsed.plan
            quotas            = $parsed.quotas
            noPremiumRequests = $parsed.noPremiumRequests
        }
        Write-Utf8File $cachePath ($toCache | ConvertTo-Json -Depth 8)
        return @{ plan = $parsed.plan; quotas = @($parsed.quotas); noPremiumRequests = $parsed.noPremiumRequests }
    } catch {
        if ($lastGood) { return $lastGood }
        return @{ plan = $null; quotas = @(); noPremiumRequests = $false }
    }
}

# Finds a function's exact original source (including its "function Name(...) { ... }"
# wrapper, so parameter declarations in the parens survive) by parsing this file's own text
# with the PowerShell AST -- the same technique scripts/test-supervisor.ps1 already uses to
# unit-test these functions without dot-sourcing the whole file. Parsed once per process and
# cached, since this file does not change while the supervisor is running.
function Get-SelfFunctionSource([string]$FunctionName) {
    if (-not $script:selfAst) {
        $tokens = $null; $parseErrors = $null
        $script:selfAst = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$tokens, [ref]$parseErrors)
    }
    $found = $script:selfAst.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName },
        $true
    ) | Select-Object -First 1
    if (-not $found) { throw "Could not find function '$FunctionName' in $PSCommandPath via AST parsing." }
    return $found.Extent.Text
}

# Runs one quota-reader function (Get-ClaudeQuota, Get-CodexQuota or Get-CopilotQuota) in a
# brand-new runspace with a hard wall-clock budget, so a stalled network call (Get-ClaudeQuota's
# Invoke-RestMethod has no -TimeoutSec) or a stuck external process (Get-CopilotQuota's `gh`
# call) can never block the supervisor loop. Windows PowerShell 5.1 gives no cancellation token
# for either of those, so BeginInvoke plus a bounded wait on the async handle is the only way to
# regain control from a call that may never return; on timeout the runspace is abandoned (a
# non-blocking BeginStop, never awaited) and $Fallback is returned instead, so a slow or hanging
# reader is visible in the log but never fails the cycle. -Variables keys are used verbatim as
# the assignment target inside the isolated script (e.g. "statePath", or "script:gh" for a
# function that reads $script:gh), so each dependency function sees exactly the same variable
# it would in this process. Always returns an array: the caller decides whether that array IS
# the result (Get-ClaudeQuota returns a quotas array directly) or wraps a single result object
# at index 0 (Get-CodexQuota/Get-CopilotQuota each return one object).
function Invoke-QuotaReaderBounded {
    param(
        [string]$Name, [string[]]$Dependencies = @(), [hashtable]$Variables = @{},
        [object[]]$CallArgs = @(), $Fallback, [int]$TimeoutSeconds = 2
    )
    $rs = $null; $ps = $null
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $prelude = ""
        $idx = 0
        foreach ($k in $Variables.Keys) {
            $rs.SessionStateProxy.SetVariable("inject$idx", $Variables[$k])
            $prelude += '${' + $k + '} = $inject' + $idx + "`n"
            $idx++
        }
        # Invoke-Gh runs in this isolated session for Get-CopilotQuota.  Seed its
        # script-scoped counter so the caller can collect calls made in the runspace.
        $prelude += '$script:githubCalls = 0' + "`n"
        $rs.SessionStateProxy.SetVariable("injectArgs", $CallArgs)
        $funcs = (($Dependencies + $Name) | ForEach-Object { Get-SelfFunctionSource $_ }) -join "`n"
        $body = $prelude + $funcs + "`n& " + $Name + " @injectArgs`n"
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $ps.AddScript($body) | Out-Null
        $asyncResult = $ps.BeginInvoke()
        if ($asyncResult.AsyncWaitHandle.WaitOne($TimeoutSeconds * 1000)) {
            $out = @($ps.EndInvoke($asyncResult))
            $isolatedGithubCalls = $rs.SessionStateProxy.GetVariable("script:githubCalls")
            if ($null -ne $isolatedGithubCalls) { $script:githubCalls += [int]$isolatedGithubCalls }
            if ($ps.HadErrors) { Write-Log "Write-Dashboard: $Name reported an error in isolation: $((@($ps.Streams.Error) | Select-Object -First 1).ToString())" }
            $ps.Dispose(); $rs.Close(); $rs.Dispose()
            return $out
        }
        $isolatedGithubCalls = $rs.SessionStateProxy.GetVariable("script:githubCalls")
        if ($null -ne $isolatedGithubCalls) { $script:githubCalls += [int]$isolatedGithubCalls }
        Write-Log "Write-Dashboard: $Name took longer than ${TimeoutSeconds}s (> ${TimeoutSeconds}s); using a fallback result and moving on"
        try { $ps.BeginStop($null, $null) | Out-Null } catch { }
        return @($Fallback)
    } catch {
        Write-Log "Write-Dashboard: $Name could not be read in isolation: $($_.Exception.Message)"
        try { if ($ps) { $ps.Dispose() } } catch { }
        try { if ($rs) { $rs.Close(); $rs.Dispose() } } catch { }
        return @($Fallback)
    }
}

function Write-Dashboard([hashtable]$Queue, [string]$NextAction, $QueueFetchedAt, [string]$Trigger = "cycle") {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    # Remembered so the heartbeat can re-export between cycles (see Update-DashboardIfStale): a
    # review with revisions is ONE cycle that can last hours, during which the queue snapshot is
    # the best we have but quotas, sessions, tokens and the running session must not freeze.
    $script:lastDashboardArgs = @{ Queue = $Queue; NextAction = $NextAction; QueueFetchedAt = $QueueFetchedAt }
    try {
        $since = (Get-Date).AddHours(-24)
        # 12000 lines, not 4000: the 20 s heartbeat writes ~4300 debug lines a day, which pushed real
        # sessions out of the 24 h window and under-counted them.
        $logLines = if (Test-Path $logPath) { @(Get-Content -Path $logPath -Encoding utf8 -Tail 12000) } else { @() }
        $providers = @{}
        $state = Get-ProviderState
        foreach ($p in $script:AllProviders) {
            $u = Get-ProviderCooldown $p
            $rec = if ($state.ContainsKey($p)) { $state[$p] } else { $null }
            $plan = $null
            $quotas = @()
            $accounts = @()
            $noPremiumRequests = $null
            if ($p -eq "claude") {
                $plan = Get-ClaudePlanLabel
                $quotas = @(Invoke-QuotaReaderBounded -Name "Get-ClaudeQuota" `
                    -Dependencies @("Write-Log", "Write-Utf8File", "ConvertFrom-ClaudeUsageResponse") `
                    -Variables @{ statePath = $statePath; logPath = $logPath } -Fallback @() -TimeoutSeconds 2)
            } elseif ($p -eq "codex") {
                $sessionsRoot = Join-Path $env:USERPROFILE ".codex\sessions"
                $codexResult = @(Invoke-QuotaReaderBounded -Name "Get-CodexQuota" -CallArgs @($sessionsRoot) `
                    -Fallback ([pscustomobject]@{ plan = $null; quotas = @() }) -TimeoutSeconds 2)
                $codexQuota = if ($codexResult.Count -gt 0) { $codexResult[0] } else { [pscustomobject]@{ plan = $null; quotas = @() } }
                # auth.json over the transcript: the transcript's plan_type is as old as that
                # login's last session, the token claim is refreshed on every login/refresh.
                $primaryIdentity = Get-CodexAccountIdentity
                $plan = if ($primaryIdentity.plan) { $primaryIdentity.plan } else { $codexQuota.plan }
                $quotas = @($codexQuota.quotas)
                # One entry per login when there is more than one: its own cooldown and its own
                # quota bars, read from that CODEX_HOME's session transcripts.
                $logins = @(Get-ProviderAccounts $p)
                if ($logins.Count -gt 1) {
                    foreach ($a in $logins) {
                        $au = Get-AccountCooldown $a.key
                        $aq = if ($a.codexHome) { Get-CodexQuota (Join-Path $a.codexHome "sessions") } else { $codexQuota }
                        $arec = if ($state.ContainsKey($a.key)) { $state[$a.key] } else { $null }
                        $aid = if ($a.codexHome) { Get-CodexAccountIdentity $a.codexHome } else { $primaryIdentity }
                        $accounts += [pscustomobject]@{
                            key = $a.key; label = $a.label; ready = ($null -eq $au)
                            cooldownUntil = if ($au) { $au.ToString("o") } else { $null }
                            lastMessage = if ($arec) { [string]$arec.reason } else { $null }
                            plan = if ($aid.plan) { $aid.plan } else { $aq.plan }
                            accountId = $aid.accountId
                            quotas = @($aq.quotas)
                        }
                    }
                }
            } elseif ($p -eq "copilot") {
                $copilotResult = @(Invoke-QuotaReaderBounded -Name "Get-CopilotQuota" `
                    -Dependencies @("Write-Utf8File", "ConvertFrom-CopilotUserResponse", "Invoke-GhJson", "Invoke-Gh") `
                    -Variables @{ statePath = $statePath; "script:gh" = $script:gh } `
                    -Fallback (@{ plan = $null; quotas = @(); noPremiumRequests = $false }) -TimeoutSeconds 2)
                $copilotQuota = if ($copilotResult.Count -gt 0) { $copilotResult[0] } else { @{ plan = $null; quotas = @(); noPremiumRequests = $false } }
                $plan = $copilotQuota.plan
                $quotas = @($copilotQuota.quotas)
                $noPremiumRequests = [bool]$copilotQuota.noPremiumRequests
            }
            $providerFields = [ordered]@{
                installed     = [bool](Require-Command $p)
                ready         = ($null -eq $u)
                cooldownUntil = if ($u) { $u.ToString("o") } else { $null }
                lastMessage   = if ($rec) { [string]$rec.reason } else { $null }
                recordedAt    = if ($rec) { [string]$rec.recordedAt } else { $null }
                plan          = $plan
                quotas        = $quotas
            }
            if ($p -eq "copilot") { $providerFields["noPremiumRequests"] = $noPremiumRequests }
            if ($accounts.Count -gt 0) { $providerFields["accounts"] = $accounts }
            $providers[$p] = [pscustomobject]$providerFields
        }
        $sessions = @(Get-RecentSessions $since $logLines)
        $window5 = (Get-Date).AddHours(-5)
        $usage = @{}
        foreach ($p in $script:AllProviders) {
            $mine = @($sessions | Where-Object { $_.provider -eq $p })
            $inWindow5 = @($mine | Where-Object { [datetime]::Parse($_.startedAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) -ge $window5 })
            $tok24 = 0; $cr24 = 0; foreach ($x in $mine) { if ($x.tokens) { $tok24 += [int64]$x.tokens }; if ($x.tokensCacheRead) { $cr24 += [int64]$x.tokensCacheRead } }
            $tok5 = 0; $cr5 = 0; foreach ($x in $inWindow5) { if ($x.tokens) { $tok5 += [int64]$x.tokens }; if ($x.tokensCacheRead) { $cr5 += [int64]$x.tokensCacheRead } }
            $usage[$p] = [pscustomobject]@{
                sessionsLast5h = $inWindow5.Count; sessionsLast24h = $mine.Count
                tokensLast5h = $tok5; tokensLast24h = $tok24
                cacheReadLast5h = $cr5; cacheReadLast24h = $cr24
            }
        }
        $reviewRounds = @{}
        foreach ($session in $sessions) {
            if ($session.tag -match '^issue-(\d+)-review-\d+(?:-run-[a-f0-9]+)?$' -and $session.outcome -eq "ok") {
                $k = $Matches[1]
                if (-not $reviewRounds.ContainsKey($k)) { $reviewRounds[$k] = 0 }
                $reviewRounds[$k]++
            }
        }
        $merges = @()
        foreach ($line in $logLines) {
            if ($line -match '^(\S+) Issue #(\d+) merged') {
                $t = $null; try { $t = [datetime]::Parse($Matches[1], $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { continue }
                if ($t -ge $since) { $merges += [pscustomobject]@{ issue = [int]$Matches[2]; at = $t.ToString("o") } }
            }
        }
        # Active lessons, newest first, capped to 5: enough for the owner to notice a repeat
        # mistake being learned without pulling the full lessons file into the dashboard.
        $lessonsSummary = [pscustomobject]@{ activeCount = 0; newest = @() }
        $lessonsPathForDashboard = Get-LessonsReadPath
        if ($lessonsPathForDashboard) {
            try {
                $activeLessons = @((Read-Lessons -Path $lessonsPathForDashboard).Active)
                $newestLessons = @($activeLessons |
                    Sort-Object @{ Expression = { [datetime]$_.date } } -Descending |
                    Select-Object -First 5 |
                    ForEach-Object { [pscustomobject]@{ id = $_.id; date = $_.date; source = $_.source; hits = [int]$_.hits } })
                $lessonsSummary = [pscustomobject]@{ activeCount = $activeLessons.Count; newest = $newestLessons }
            } catch { }
        }
        $issues = @()
        foreach ($stateName in @($Queue.Keys)) {
            foreach ($i in @($Queue[$stateName])) {
                if ($null -eq $i) { continue }
                $issues += [pscustomobject]@{
                    number = [int]$i.number; title = [string]$i.title; state = $stateName
                    provider = (Get-Field $i.body "Provider"); reviewer = (Get-Field $i.body "Reviewer")
                    objective = ((Get-IssueRefs (Get-Field $i.body "Objective")) | Select-Object -First 1)
                    reviewRounds = $(if ($reviewRounds.ContainsKey("$($i.number)")) { $reviewRounds["$($i.number)"] } else { 0 })
                    url = "https://github.com/$Repository/issues/$($i.number)"
                }
            }
        }
        $doc = [pscustomobject]@{
            updatedAt      = (Get-Date).ToString("o")
            meta           = [pscustomobject]@{ exportMs = [int]$stopwatch.ElapsedMilliseconds; githubCalls = [int]$script:githubCalls; trigger = $Trigger }
            queueFetchedAt = if ($QueueFetchedAt) { $QueueFetchedAt.ToString("o") } else { $null }
            nextAction     = $NextAction
            repository     = $Repository
            providers      = [pscustomobject]$providers
            usage          = [pscustomobject]$usage
            issues         = $issues
            sessions       = @($sessions | Select-Object -First 40)
            merges         = $merges
            lessons        = $lessonsSummary
            supervisor     = [pscustomobject]@{ pid = $PID; startedAt = $script:startedAt; version = $script:versionSha }
        }
        Write-Utf8File (Join-Path $statePath "dashboard.json") ($doc | ConvertTo-Json -Depth 8)
        $script:lastDashboardWriteAt = Get-Date
        $stopwatch.Stop()
    } catch {
        Write-Log "dashboard.json not written: $($_.Exception.Message)"
    }
}

# Called from every heartbeat (Write-Live). Re-runs the export with the last cycle's queue
# snapshot when dashboard.json is older than 5 minutes, so a long review/revision loop no
# longer leaves the owner looking at quotas and sessions from hours ago. Never re-entered,
# never allowed to throw into the heartbeat, and skipped entirely until the first cycle export
# has recorded its arguments.
function Update-DashboardIfStale {
    if ($DryRun) { return }
    if (-not $script:lastDashboardArgs -or $script:dashboardRefreshing) { return }
    $last = $script:lastDashboardWriteAt
    if ($last -and ((Get-Date) - $last).TotalMinutes -lt 5) { return }
    $script:dashboardRefreshing = $true
    try {
        $a = $script:lastDashboardArgs
        Write-Dashboard $a.Queue $a.NextAction $a.QueueFetchedAt "heartbeat"
    } catch {
        Write-Log "dashboard heartbeat refresh failed: $($_.Exception.Message)"
    } finally {
        $script:dashboardRefreshing = $false
    }
}

# A single small file an operator can read instead of piecing the current state together
# from the log, the issues and the worktrees.
function Write-Status([hashtable]$Fields) {
    if ($DryRun) { return }
    $cool = @{}
    foreach ($p in $script:AllProviders) {
        $u = Get-ProviderCooldown $p
        $logins = @(Get-ProviderAccounts $p)
        $cool[$p] = if ($u) { "cooling until " + $u.ToString("yyyy-MM-dd HH:mm") } elseif ($logins.Count -gt 1) { "ready (account " + (Get-ReadyAccount $p).label + " of " + $logins.Count + ")" } else { "ready" }
    }
    $base = @{ updatedAt = (Get-Date).ToString("o"); providers = $cool }
    foreach ($k in $Fields.Keys) { $base[$k] = $Fields[$k] }
    try { [pscustomobject]$base | ConvertTo-Json -Depth 6 | Set-Content -Path $statusPath -Encoding utf8 -ErrorAction Stop } catch { }
}

function Require-Command([string]$Name) {
    $override = [Environment]::GetEnvironmentVariable(($Name.ToUpperInvariant() + "_COMMAND"))
    if ([string]::IsNullOrWhiteSpace($override)) { $override = $Name }
    $command = @(Get-Command $override -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($null -eq $command) { return $null }
    return [string]$command.Source
}

# The default partner: claude<->codex as always; a copilot-authored task defaults to a claude
# review. Availability-aware choices go through Get-EffectiveReviewer/Get-EffectiveAuthor.
function Other-Provider([string]$Provider) { if ($Provider -eq "claude") { "codex" } else { "claude" } }

function Invoke-Gh([string[]]$A) {
    $script:githubCalls++
    $out = & $script:gh @A 2>&1
    $code = $LASTEXITCODE
    $text = ($out | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ } }) -join "`n"
    return [pscustomobject]@{ Code = $code; Text = $text }
}

function Invoke-GhJson([string[]]$A) {
    $r = Invoke-Gh $A
    if ($r.Code -ne 0 -or [string]::IsNullOrWhiteSpace($r.Text)) { return @() }
    # PowerShell 5.1 emits a JSON array as ONE object; piping through ForEach-Object unrolls it.
    $parsed = ConvertFrom-Json -InputObject $r.Text
    return @($parsed | ForEach-Object { $_ })
}

# A failure must reach the owner's dashboard the moment it happens. The failed list is refetched
# at most every 10 minutes and only between cycles, and a review cycle can run for hours, so a
# task that fails during another task's long review would otherwise stay invisible until then.
# Patch the cached queue (the issue leaves every other list, joins `failed`), mark the label
# cache stale for the next cycle, and re-export now.
function Register-FailureOnDashboard([object]$Issue) {
    if ($DryRun) { return }
    $n = [int]$Issue.number
    $script:queueLabelsFetchedAt = $null
    $failed = @(@($script:allFailed) | Where-Object { $_ -and [int]$_.number -ne $n }) + @($Issue)
    $script:allFailed = $failed
    if (-not $script:lastDashboardArgs) { return }
    $a = $script:lastDashboardArgs
    $queue = @{}
    foreach ($k in @($a.Queue.Keys)) { $queue[$k] = @(@($a.Queue[$k]) | Where-Object { $_ -and [int]$_.number -ne $n }) }
    $queue["failed"] = $failed
    $script:lastDashboardArgs = @{ Queue = $queue; NextAction = $a.NextAction; QueueFetchedAt = (Get-Date) }
    if ($script:dashboardRefreshing) { return }
    $script:dashboardRefreshing = $true
    try { Write-Dashboard $queue $a.NextAction (Get-Date) "failure" } finally { $script:dashboardRefreshing = $false }
}

# The three dashboard-only label queries (blocked/failed/objective-planned) are refetched at
# most every 5th cycle or every 10 minutes since the last fetch, whichever comes first -- a
# single rule combining both thresholds with OR, so a burst of fast cycles is still bounded by
# wall-clock time and a slow poll interval is still bounded by cycle count. Pure: the caller
# passes the current time in rather than the function reading Get-Date itself, so identical
# arguments always produce identical results and it is unit-testable without a live loop.
function Test-QueueLabelsStale($LastFetchedAt, [int]$CyclesSinceFetch, [datetime]$Now) {
    if ($null -eq $LastFetchedAt) { return $true }
    if ($CyclesSinceFetch -ge 5) { return $true }
    if (($Now - $LastFetchedAt).TotalMinutes -ge 10) { return $true }
    return $false
}

function Get-IssuesWithLabel([string]$Label, [int]$Limit = 20) {
    return Invoke-GhJson @("issue", "list", "--repo", $Repository, "--label", $Label, "--state", "open", "--limit", "$Limit", "--json", "number,title,body,labels,createdAt")
}

function Get-Issue([int]$Number) {
    $r = Invoke-GhJson @("issue", "view", "$Number", "--repo", $Repository, "--json", "number,title,body,labels,state")
    if ($r.Count -eq 0) { return $null }
    return $r[0]
}

function Ensure-Label([string]$Name, [string]$Color, [string]$Description) {
    Invoke-Gh @("label", "create", $Name, "--repo", $Repository, "--color", $Color, "--description", $Description, "--force") | Out-Null
}

function Set-IssueLabels([int]$Number, [string[]]$Remove, [string[]]$Add) {
    $ghArgs = @("issue", "edit", "$Number", "--repo", $Repository)
    foreach ($l in $Remove) { if ($l) { $ghArgs += @("--remove-label", $l) } }
    foreach ($l in $Add) { if ($l) { $ghArgs += @("--add-label", $l) } }
    Invoke-Gh $ghArgs | Out-Null
}

function Comment([int]$Number, [string]$Body) {
    $file = Join-Path $statePath ("comment-$Number-$(Get-Random).md")
    Write-Utf8File $file $Body
    Invoke-Gh @("issue", "comment", "$Number", "--repo", $Repository, "--body-file", $file) | Out-Null
    Remove-Item $file -Force -ErrorAction SilentlyContinue
}

function Read-Handoff([string]$Worktree) {
    # Preferred location is git-ignored so it never enters the diff; root is accepted as a fallback.
    foreach ($candidate in @((Join-Path $Worktree ".agent-state\HANDOFF.md"), (Join-Path $Worktree "HANDOFF.md"))) {
        if (Test-Path $candidate) {
            # Same BOM-stripping as Get-Field: either agent CLI may write UTF-8 with a leading BOM,
            # and this text is copied verbatim into the PR body and the reviewer's prompt.
            return (Get-Content -Raw $candidate -Encoding utf8).TrimStart([char]0xFEFF)
        }
    }
    return "_The agent did not write a handoff._"
}

function Get-Field([string]$Body, [string]$Name) {
    $Body = ([string]$Body).TrimStart([char]0xFEFF)
    if ($Body -match "(?im)^\s*$([regex]::Escape($Name)):\s*(.+?)\s*$") { return $Matches[1].Trim() }
    return $null
}

function Get-IssueRefs([string]$Text) {
    $refs = @()
    foreach ($m in [regex]::Matches([string]$Text, "#(\d+)")) { $refs += [int]$m.Groups[1].Value }
    return $refs
}

function Get-OwnedPaths([string]$Body) {
    # The "- `path`" bullets under "## Owned paths" in a task issue body (the planner writes them).
    if ([string]::IsNullOrWhiteSpace($Body)) { return @() }
    $m = [regex]::Match($Body, '(?ms)^##\s*Owned paths\s*\r?\n(.*?)(?=^##\s|\z)')
    if (-not $m.Success) { return @() }
    $paths = @()
    foreach ($line in ($m.Groups[1].Value -split "\r?\n")) {
        $t = $line.Trim()
        # A backtick-quoted path may carry a trailing "(auto: ...)" annotation (see
        # Format-OwnedPathsSection); only the backtick-quoted path itself is the owned path.
        if ($t -match '^-\s*`([^`]+)`\s*(?:\(.*\))?\s*$') { $paths += $Matches[1].Trim() }
        elseif ($t -match '^-\s*([^`]+?)\s*$') { $paths += $Matches[1].Trim() }
    }
    return $paths
}

function Get-TaskReasoning([string]$Body) {
    # Codex reasoning effort for this task. Documentation-only tasks (every owned path is a
    # document: .md/.txt/.yaml/.yml/.json, or a folder under docs/) get $DocsReasoning;
    # anything that touches code keeps the default. Codex reports 35-50K tokens per review at
    # "medium" whether the diff is a PowerShell script or an ADR; the reasoning share of that is
    # the part this trims. Only codex has the knob; claude ignores it.
    $paths = @(Get-OwnedPaths $Body)
    if ($paths.Count -eq 0) { return "medium" }
    foreach ($p in $paths) {
        $q = $p.Replace('\', '/').TrimStart('./')
        if ($q -notmatch '\.(md|txt|ya?ml|json)$' -and $q -notmatch '/$') { return "medium" }
        if ($q -match '/$' -and $q -notmatch '^docs/') { return "medium" }
    }
    return $DocsReasoning
}

function Limit-Text([string]$Text, [int]$MaxChars, [string]$What = "text") {
    # Keeps the head of an over-long block and says so, for prompts where the full version is
    # available elsewhere (the pull request body) and every character is paid for per round.
    if (-not $Text -or $Text.Length -le $MaxChars) { return $Text }
    return $Text.Substring(0, $MaxChars).TrimEnd() + "`n`n_[$What truncated by the supervisor at $MaxChars characters; the full version is in the pull request body.]_"
}

function Find-ExistingTaskIssues([int]$ObjectiveNumber) {
    # Quoted for an exact phrase match: GitHub's unquoted keyword search can under-match
    # "Objective: #12 in:body" (e.g. treating ':' and '#' as separators), which would leave
    # a fully completed objective open forever with no error. The Get-IssueRefs filter below
    # re-verifies the match against the actual "Objective:" field, same as Check-ObjectiveDone.
    #
    # The embedded quotes are passed as \" so that the one extra pair of quotes Windows
    # PowerShell 5.1 wraps around any array element containing whitespace still parses, under
    # CommandLineToArgvW, into the single argument `"Objective: #12" in:body`. The previous
    # trick (doubling the quotes, `""Objective: #12"" in:body`) stopped working with the September
    # 2026 Windows update of PowerShell 5.1 (5.1.26100.9444): gh received the phrase split in two
    # and refused every search, so planning of every new objective was deferred indefinitely (and,
    # because the supervisor was never idle, it never self-updated either). The \" form is
    # verified on that build.
    $searchPhrase = '\"Objective: #' + $ObjectiveNumber + '\" in:body'
    $r = Invoke-Gh @("issue", "list", "--repo", $Repository, "--state", "all",
        "--search", $searchPhrase, "--limit", "100",
        "--json", "number,title,body,labels,state")
    if ($r.Code -ne 0) { return [pscustomobject]@{ Ok = $false; Issues = @() } }
    $all = @()
    if (-not [string]::IsNullOrWhiteSpace($r.Text)) {
        try { $all = @((ConvertFrom-Json -InputObject $r.Text) | ForEach-Object { $_ }) }
        catch { return [pscustomobject]@{ Ok = $false; Issues = @() } }
    }
    $matched = @($all | Where-Object { (Get-IssueRefs (Get-Field $_.body "Objective")) -contains $ObjectiveNumber })
    return [pscustomobject]@{ Ok = $true; Issues = $matched }
}

function Load-State([int]$Number, [ref]$Ok) {
    # Returned as a hashtable so new keys can be added freely. $Ok (if given) is set to $false
    # only when the file EXISTS but could not be read/parsed -- e.g. a write was interrupted
    # mid-way (see Save-State's atomic replace below, which makes this rare but not impossible
    # for a file written by an older version of this script, or external corruption). Callers
    # that are about to trust a safety-critical field (pendingPush) must check $Ok and fail
    # closed instead of silently accepting the all-defaults hashtable this still returns.
    if ($Ok) { $Ok.Value = $true }
    $state = @{ revisions = 0; escalated = $false; reviewFailures = 0; pendingPush = $false }
    $f = Join-Path $statePath "issue-$Number.json"
    if (Test-Path $f) {
        try {
            $obj = Get-Content -Raw $f -Encoding utf8 | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) { $state[$p.Name] = $p.Value }
        } catch {
            if ($Ok) { $Ok.Value = $false }
            Write-Log "Could not read/parse state file for issue #${Number} ($($_.Exception.Message)); treating as unknown, not as all-defaults"
        }
    }
    return $state
}
function Save-State([int]$Number, $State) {
    # Atomic replace: write to a process-unique temp file, then Move-Item over the real path.
    # A plain Set-Content can be left truncated/partial if the process dies mid-write (or the
    # disk is full), which Load-State would then have to guess about; a failed rename here
    # instead leaves the PREVIOUS state file intact and reports failure to the caller, which
    # for the safety-critical call sites (pendingPush before a revision launch) must abort
    # rather than proceed as if the new state were durably recorded.
    $path = Join-Path $statePath "issue-$Number.json"
    $tmp = "$path.tmp-$PID-$([Guid]::NewGuid().ToString('N'))"
    try {
        $json = $State | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
        return $true
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Write-Log "Could not durably save state for issue #${Number}: $($_.Exception.Message)"
        return $false
    }
}

function Fill-Template([string]$Name, [hashtable]$Values) {
    $text = Get-Content -Raw -Path (Join-Path $promptDir "$Name.md") -Encoding utf8
    foreach ($k in $Values.Keys) { $text = $text.Replace("{{$k}}", [string]$Values[$k]) }
    return $text
}

function Get-LessonsSection {
    # Read fresh every call: lessons.md can gain entries mid-run (see the reviewer-round
    # auto-learn block below), and each prompt fill should see the latest active lessons.
    $readPath = Get-LessonsReadPath
    if (-not $readPath) { return '' }
    return Build-LessonsSection -Lessons (Read-Lessons -Path $readPath)
}

function Extract-Json([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    # Three candidates, in order: the shortest fenced object, the longest fenced object (a JSON
    # string that itself contains "}" followed by a fence -- a task body with an acceptance
    # block, say -- defeats the lazy match), then first "{" to last "}".
    $candidates = @()
    $m = [regex]::Match($Text, '```json\s*(\{[\s\S]*?\})\s*```')
    if ($m.Success) { $candidates += $m.Groups[1].Value }
    $g = [regex]::Match($Text, '```json\s*(\{[\s\S]*\})\s*```')
    if ($g.Success) { $candidates += $g.Groups[1].Value }
    $start = $Text.IndexOf("{"); $end = $Text.LastIndexOf("}")
    if ($start -ge 0 -and $end -gt $start) { $candidates += $Text.Substring($start, $end - $start + 1) }
    foreach ($candidate in $candidates) {
        try { return ($candidate | ConvertFrom-Json) } catch { }
    }
    # Trailing commas before a closing bracket are the one malformation models produce that a
    # strict parser rejects and a human would not notice.
    foreach ($candidate in $candidates) {
        $relaxed = [regex]::Replace($candidate, ',(\s*[}\]])', '$1')
        if ($relaxed -ne $candidate) { try { return ($relaxed | ConvertFrom-Json) } catch { } }
    }
    return $null
}

function Get-ProcessTreeIds([int]$RootProcId) {
    # Walks Win32_Process parent links breadth-first. taskkill /T does its own tree walk at the
    # moment it runs; snapshotting the tree ourselves BEFORE killing means a descendant that
    # taskkill fails to reach (already reparented, a race, permissions) is still something we
    # check for afterwards, instead of only ever looking at the one PID the supervisor started.
    $ids = New-Object System.Collections.Generic.List[int]
    $ids.Add($RootProcId)
    $i = 0
    while ($i -lt $ids.Count) {
        $parent = $ids[$i]; $i++
        $children = @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$parent" -ErrorAction SilentlyContinue)
        foreach ($c in $children) {
            $cid = [int]$c.ProcessId
            if (-not $ids.Contains($cid)) { $ids.Add($cid) }
        }
    }
    return $ids
}

function Confirm-ProcessTerminated([int]$ProcId, [int64]$StartTicks) {
    # Fires taskkill and only reports success once a re-check actually confirms the WHOLE process
    # tree is gone (or a PID was recycled by an unrelated process) -- taskkill's own exit code does
    # not guarantee every descendant is actually dead (e.g. the wrapper powershell.exe dies but a
    # claude/codex CLI child it spawned survives), and callers must not treat "we tried to kill it"
    # as "it is safe to touch the worktree now".
    $treeIds = Get-ProcessTreeIds $ProcId
    & taskkill /T /F /PID $ProcId 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    foreach ($id in $treeIds) {
        $live = Get-Process -Id $id -ErrorAction SilentlyContinue
        if (-not $live) { continue }
        if ($id -eq $ProcId -and $StartTicks -and $live.StartTime.Ticks -ne $StartTicks) { continue }
        return $false
    }
    return $true
}

# ----------------------------------------------------------------------------- last visible agent action
# Cheap "what is it doing right now" for the live.json heartbeat: reads only the tail (~64 KB) of
# one provider-specific output file -- never the whole transcript -- and extracts nothing but a
# tool name, a file path/pattern, or a short command line. Never prompt text, secrets, or full
# model output. Every reader returns @{ at; kind; summary } or $null (nothing usable found yet);
# Get-LastAgentAction is the only entry point callers use and always returns a safe placeholder
# instead of throwing.
function Read-FileTail([string]$Path, [int]$MaxBytes = 65536) {
    # Seeks straight to the last $MaxBytes bytes so this stays fast against a multi-gigabyte
    # transcript -- it never reads, or even measures, anything before that point.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $len = $fs.Length
        $take = [int][Math]::Min($len, [int64]$MaxBytes)
        $start = $len - $take
        if ($start -gt 0) { [void]$fs.Seek($start, [System.IO.SeekOrigin]::Begin) }
        $buffer = New-Object byte[] $take
        $read = 0
        while ($read -lt $take) {
            $n = $fs.Read($buffer, $read, $take - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        # A seek that lands mid-line (any file bigger than $MaxBytes) leaves one corrupt leading
        # fragment; drop everything up to the first newline unless the read started at byte 0.
        if ($start -gt 0) {
            $nl = $text.IndexOf("`n")
            $text = if ($nl -ge 0) { $text.Substring($nl + 1) } else { "" }
        } elseif ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
            # Encoding.GetString (unlike StreamReader) does not strip a UTF-8 BOM; a file written
            # with Set-Content -Encoding utf8 (or Claude/Codex's own writer) starts with one, and
            # a stray U+FEFF before the first "{" fails ConvertFrom-Json for that line.
            $text = $text.Substring(1)
        }
        return $text
    } catch { return $null }
    finally { if ($fs) { $fs.Dispose() } }
}

function Limit-Summary([string]$Text, [int]$MaxLength = 120) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $MaxLength) { $t = $t.Substring(0, $MaxLength - 3).TrimEnd() + "..." }
    return $t
}

# Claude Code's own tool names, shared by every non-interactive session (see Get-ClaudeJsonlTokens
# above for why that JSONL is the only place to look).
function ConvertTo-ClaudeToolAction([string]$Name, $ToolInput) {
    switch -regex ($Name) {
        '^(Edit|MultiEdit|Write)$' {
            $path = if ($ToolInput -and $ToolInput.file_path) { [string]$ToolInput.file_path } else { "" }
            return @{ kind = "edit"; summary = (Limit-Summary "$Name $path") }
        }
        '^(Read|Glob|Grep)$' {
            $target = if ($ToolInput -and $ToolInput.file_path) { [string]$ToolInput.file_path } elseif ($ToolInput -and $ToolInput.pattern) { [string]$ToolInput.pattern } else { "" }
            return @{ kind = "read"; summary = (Limit-Summary "$Name $target") }
        }
        '^Bash$' {
            $cmd = if ($ToolInput -and $ToolInput.command) { [string]$ToolInput.command } else { "" }
            return @{ kind = "run"; summary = (Limit-Summary "Bash $cmd") }
        }
        default { return @{ kind = "unknown"; summary = (Limit-Summary $Name) } }
    }
}

function Get-ClaudeLastAction([string]$WorkDir) {
    $slug = ($WorkDir -replace '[:\\]', '-')
    $dir = Join-Path $env:USERPROFILE ".claude\projects\$slug"
    if (-not (Test-Path $dir)) { return $null }
    $file = Get-ChildItem -Path $dir -Filter "*.jsonl" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $file) { return $null }
    $tail = Read-FileTail $file.FullName 65536
    if (-not $tail) { return $null }
    $lines = @($tail -split "`r?`n" | Where-Object { $_ -and $_.Trim() })
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $obj = $null
        try { $obj = $lines[$i] | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if (-not $obj.message -or -not $obj.message.content) { continue }
        $toolUses = @($obj.message.content | Where-Object { $_.type -eq "tool_use" })
        if ($toolUses.Count -eq 0) { continue }
        $tu = $toolUses[-1]
        $mapped = ConvertTo-ClaudeToolAction ([string]$tu.name) $tu.input
        $at = $null
        if ($obj.timestamp) { try { $at = ([datetime]::Parse($obj.timestamp, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime().ToString("o") } catch { } }
        return @{ at = $at; kind = $mapped.kind; summary = $mapped.summary }
    }
    return $null
}

# Codex CLI's rollout JSONL carries one item per turn; a tool call shows up either as a top-level
# {"type":"function_call",...} record or wrapped in {"type":"response_item","payload":{"type":
# "function_call"|"exec_command", "name":..., "arguments":...}}. "arguments" is itself a
# JSON-encoded string, and the command/path actually lives under any of "command"/"cmd" (the
# shell and exec_command shapes) or "input"/"patch" (apply_patch's payload -- itself a
# "*** Begin Patch" body that names the touched file on a "*** Update/Add/Delete File: <path>"
# header line; only that path is ever kept, never the diff hunks that follow it). A structured
# (JSON) shape this does not recognise returns "" rather than the raw JSON or patch text, so an
# unfamiliar payload can never leak its arguments or a diff body into a summary; only a bare,
# already-unstructured "arguments" string falls back to itself, unchanged from before.
function Get-CodexActionDetail($Item) {
    $sources = @()
    # A bare (non-JSON) "arguments" string is a plausible, if unusual, shape for a simple tool
    # call -- kept as a last-resort fallback below so this does not regress behaviour for it,
    # but only structured fields (command/cmd/input/patch/file_path/path) are ever preferred.
    $fallbackRaw = $null
    if ($Item.arguments -is [string]) {
        $parsedArgs = $null
        try { $parsedArgs = $Item.arguments | ConvertFrom-Json -ErrorAction Stop } catch { $parsedArgs = $null }
        if ($parsedArgs) { $sources += $parsedArgs } else { $fallbackRaw = $Item.arguments }
    } elseif ($Item.arguments) {
        $sources += $Item.arguments
    }
    $sources += $Item

    foreach ($src in $sources) {
        if ($null -eq $src) { continue }
        foreach ($key in @('command', 'cmd')) {
            if ($src.PSObject.Properties.Name -contains $key -and $src.$key) {
                $val = $src.$key
                if ($val -is [array]) { return (($val | ForEach-Object { [string]$_ }) -join " ") }
                return [string]$val
            }
        }
        foreach ($patchKey in @('input', 'patch')) {
            if ($src.PSObject.Properties.Name -contains $patchKey -and $src.$patchKey -is [string] -and
                $src.$patchKey -match '\*\*\* (?:Begin Patch|(?:Update|Add|Delete) File:)') {
                $m = [regex]::Match($src.$patchKey, '\*\*\* (?:Update|Add|Delete) File:\s*(.+)')
                if ($m.Success) { return $m.Groups[1].Value.Trim() }
                return ""
            }
        }
        foreach ($key in @('file_path', 'path')) {
            if ($src.PSObject.Properties.Name -contains $key -and $src.$key) { return [string]$src.$key }
        }
    }
    if ($fallbackRaw) { return [string]$fallbackRaw }
    return ""
}

function ConvertTo-CodexToolAction([string]$Name, [string]$Detail) {
    switch -regex ($Name) {
        '(?i)^(apply_patch|edit_file|write_file|patch)$' { return @{ kind = "edit"; summary = (Limit-Summary "$Name $Detail") } }
        '(?i)^(read_file|view_file|list_dir|glob|grep|search)$' { return @{ kind = "read"; summary = (Limit-Summary "$Name $Detail") } }
        '(?i)^(shell|exec_command|bash|run_command)$' { return @{ kind = "run"; summary = (Limit-Summary "$Name $Detail") } }
        default { return @{ kind = "unknown"; summary = (Limit-Summary $Name) } }
    }
}

# Every Codex rollout JSONL opens with one {"type":"session_meta","payload":{"cwd":...}} line
# naming the working directory the session was launched in (run-agent.ps1 passes it via
# "-C $WorkDir"). Reading only that first line -- never the rest of a possibly huge file --
# is enough to tell which of several concurrent sessions belongs to this task, so Get-CodexLastAction
# below never reports another task's action just because its session file happens to be the most
# recently written one on the whole host.
function Get-CodexSessionCwd([string]$Path) {
    try {
        $reader = New-Object System.IO.StreamReader($Path, [System.Text.Encoding]::UTF8, $true)
        try { $line = $reader.ReadLine() } finally { $reader.Dispose() }
        if ([string]::IsNullOrWhiteSpace($line)) { return $null }
        $obj = $null
        try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
        $payload = if ($obj.payload) { $obj.payload } else { $obj }
        if ($payload.cwd) { return [string]$payload.cwd }
        return $null
    } catch { return $null }
}

function Get-NormalizedWorkDir([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    return $Path.Trim().TrimEnd('\', '/').Replace('/', '\').ToLowerInvariant()
}

function Get-CodexLastAction([string]$WorkDir, [string]$CodexHome = "") {
    $codexHomeDir = if ($CodexHome) { $CodexHome } else { Join-Path $env:USERPROFILE ".codex" }
    $dir = Join-Path $codexHomeDir "sessions"
    if (-not (Test-Path $dir)) { return $null }
    $wantCwd = Get-NormalizedWorkDir $WorkDir
    if (-not $wantCwd) { return $null }
    # No cap on how many session files are considered: capping at, say, the 25 most recently
    # modified files used to mean a task whose session fell just outside that window (because
    # enough *other* sessions -- other tasks, other worktrees, other providers -- had been
    # written more recently on the same host) silently returned "no action" even though its
    # session file was sitting right there. Get-CodexSessionCwd only reads one line per file
    # (see above), so scanning every candidate stays cheap; sorting newest-first just means a
    # match is typically found within the first few files in the common case of one active task.
    $candidates = Get-ChildItem -Path $dir -Filter "*.jsonl" -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    $file = $null
    foreach ($c in $candidates) {
        $cwd = Get-CodexSessionCwd $c.FullName
        if ($cwd -and (Get-NormalizedWorkDir $cwd) -eq $wantCwd) { $file = $c; break }
    }
    if (-not $file) { return $null }
    $tail = Read-FileTail $file.FullName 65536
    if (-not $tail) { return $null }
    $lines = @($tail -split "`r?`n" | Where-Object { $_ -and $_.Trim() })
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $obj = $null
        try { $obj = $lines[$i] | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $item = if ($obj.payload -and $obj.payload.type) { $obj.payload } else { $obj }
        if ([string]$item.type -notmatch '^(function_call|exec_command)$') { continue }
        $name = if ($item.name) { [string]$item.name } else { [string]$item.type }
        $detail = Get-CodexActionDetail $item
        $mapped = ConvertTo-CodexToolAction $name $detail
        $at = $null
        $ts = if ($obj.timestamp) { $obj.timestamp } else { $item.timestamp }
        if ($ts) { try { $at = ([datetime]::Parse([string]$ts, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime().ToString("o") } catch { } }
        return @{ at = $at; kind = $mapped.kind; summary = $mapped.summary }
    }
    return $null
}

# Copilot CLI has no structured transcript this supervisor can read. Invoke-Agent redirects the
# run-agent.ps1 child process's own stdout to "$Tag.stdout.txt", and run-agent.ps1's copilot
# branch now streams each line of the CLI's native output to its own stdout (via Write-Output)
# as it arrives, while still collecting the same lines to write "$Tag.output.md" once the call
# returns. So "$Tag.stdout.txt" fills continuously during the run and is tried first here; the
# fallback to "$Tag.output.md" only matters for a run that predates this change or exited before
# any output was flushed.
#
# Spinner frames, blank lines and bare progress punctuation are skipped; the last real line left
# is reduced to a short summary. Spinner glyphs (the Braille Patterns block, U+2800-U+28FF) and
# the two common progress-dot characters (U+00B7 middle dot, U+2022 bullet) are matched by numeric
# code point, never as a literal non-ASCII character in this source file, so this is immune to
# whatever codepage the file happens to be read back with.
function Test-CopilotNoiseChar([char]$Ch) {
    if ([char]::IsWhiteSpace($Ch)) { return $true }
    $code = [int]$Ch
    if ($code -ge 0x2800 -and $code -le 0x28FF) { return $true }
    if ($code -eq 0x00B7 -or $code -eq 0x2022) { return $true }
    return @('.', '-', '_', '=', '~', '*', '#', '|', '/', '\') -contains $Ch
}

function Test-CopilotNoiseLine([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $true }
    foreach ($ch in $Text.ToCharArray()) {
        if (-not (Test-CopilotNoiseChar $ch)) { return $false }
    }
    return $true
}

function ConvertTo-CopilotLineAction([string]$Line) {
    if ($Line -match '^(?:\$|>|Running:|Executing:)\s*(.+)$') {
        return @{ kind = "run"; summary = (Limit-Summary $Matches[1]) }
    }
    # Anything else is free-form assistant prose. The heartbeat's privacy rule allows only tool
    # names, paths and short command lines to be extracted -- never prompt text or full model
    # output -- so unlike the run-shaped line above, this never echoes the line itself, only a
    # length-only placeholder that carries no content from it.
    return @{ kind = "message"; summary = "agent message ($($Line.Length) chars)" }
}

function Get-CopilotLastAction([string]$Tag) {
    $tail = $null
    foreach ($candidate in @("$Tag.stdout.txt", "$Tag.output.md")) {
        $tail = Read-FileTail (Join-Path $statePath $candidate) 65536
        if ($tail) { break }
    }
    if (-not $tail) { return $null }
    $lines = @($tail -split "`r?`n")
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        # Strip ANSI escape/color codes before judging whether anything real is left on the line.
        $clean = [regex]::Replace($lines[$i], "`e\[[0-9;]*[A-Za-z]", "").Trim()
        if (Test-CopilotNoiseLine $clean) { continue }
        $mapped = ConvertTo-CopilotLineAction $clean
        return @{ at = $null; kind = $mapped.kind; summary = $mapped.summary }
    }
    return $null
}

function Get-LastAgentAction([string]$Provider, [string]$WorkDir, [string]$Tag, [string]$CodexHome = "") {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = $null
    try {
        $result = switch ($Provider) {
            "claude" { Get-ClaudeLastAction $WorkDir }
            "codex" { Get-CodexLastAction $WorkDir $CodexHome }
            "copilot" { Get-CopilotLastAction $Tag }
            default { $null }
        }
    } catch { $result = $null }
    $sw.Stop()
    Write-Log "[debug][$Tag] lastAction read ($Provider) took $([Math]::Round($sw.Elapsed.TotalMilliseconds, 1))ms -> kind=$(if ($result) { $result.kind } else { 'unknown' })"
    if (-not $result) { return [pscustomobject]@{ at = $null; kind = "unknown"; summary = "" } }
    return [pscustomobject]@{ at = $result.at; kind = $result.kind; summary = $result.summary }
}

function Write-Live([string]$Tag, [string]$Provider, [datetime]$StartedAtUtc, [string]$Deadline, [string]$Role = "", [string]$Step = "", [string]$Summary = "", [string]$LastActionAt = "", [string]$LastActionKind = "", [string]$LastActionSummary = "") {
    # Non-blocking heartbeat written on every WaitForExit slice inside Invoke-Agent's wait loop,
    # so a human (or the dashboard, later) can see a task is alive without waiting for it to
    # finish. Role/step are derived purely from the $Tag naming convention already used at every
    # call site (see Invoke-Agent): "objective-<n>-plan", "issue-<n>-implement",
    # "issue-<n>-revise-<round>", "issue-<n>-review-<round>". Any failure here (disk full, bad
    # path, JSON failure) is caught and logged by the caller's try/catch -- it must never affect
    # Invoke-Agent's return value or its timeout/kill/worker.json behaviour.
    $issueNumber = $null
    if ($Tag -match '^issue-(\d+)-') { $issueNumber = [int]$Matches[1] }

    # PowerShell variable names are case-insensitive: "$role = ..." here would silently overwrite
    # the $Role parameter, so an explicit -Role "supervisor" ended up as "unknown" on every
    # supervisor step (setup, acceptance, merge/export, reconciliation, idle) and the dashboard
    # showed all four roles as waiting. Distinct local names keep the parameters intact.
    $resolvedRole = "unknown"
    $resolvedStep = "unknown"
    if ($Tag -match '-plan$') { $resolvedRole = "planner"; $resolvedStep = "planner" }
    elseif ($Tag -match '-implement$') { $resolvedRole = "author"; $resolvedStep = "author" }
    elseif ($Tag -match '-revise-\d+$') { $resolvedRole = "reviser"; $resolvedStep = "revision" }
    elseif ($Tag -match '-review-\d+$') { $resolvedRole = "reviewer"; $resolvedStep = "reviewer" }
    if ($Role) { $resolvedRole = $Role }
    if ($Step) { $resolvedStep = $Step }

    $nowUtc = (Get-Date).ToUniversalTime()
    $elapsedSeconds = [int][math]::Max(0, ($nowUtc - $StartedAtUtc).TotalSeconds)

    $live = [pscustomobject]@{
        updatedAt = $nowUtc.ToString("o")
        step = $resolvedStep
        issue = $issueNumber
        role = $resolvedRole
        provider = $Provider
        tag = $Tag
        startedAt = $StartedAtUtc.ToString("o")
        elapsedSeconds = $elapsedSeconds
        deadline = $Deadline
        lastAction = if ($Summary) {
            [pscustomobject]@{ at = $nowUtc.ToString("o"); kind = "supervisor"; summary = $Summary }
        } elseif ($LastActionKind) {
            [pscustomobject]@{ at = if ($LastActionAt) { $LastActionAt } else { $null }; kind = $LastActionKind; summary = $LastActionSummary }
        } else {
            [pscustomobject]@{ at = $null; kind = "unknown"; summary = "" }
        }
    }
    $json = $live | ConvertTo-Json -Compress -Depth 5
    $byteCount = [System.Text.Encoding]::UTF8.GetByteCount($json)
    if ($byteCount -gt 4096) { throw "live.json payload is $byteCount bytes, over the 4096 limit" }
    Write-Utf8File (Join-Path $statePath "live.json") $json
    try { Update-DashboardIfStale } catch { }
}

function Invoke-Agent {
    param(
        [string]$Provider, [ValidateSet("edit", "readonly")][string]$Mode, [string]$Prompt,
        [string]$WorkDir, [string]$Tag, [int]$TimeoutMinutes, [string[]]$ExtraWritableDirs = @(),
        [string]$CodexReasoning = "medium", [switch]$ConflictSession, [switch]$ExpertSession,
        [string]$ExpertModel = ""
    )
    # Keep the logical tag for heartbeat/recovery; artifacts and accounting identify a run.
    $runTag = "$Tag-run-$([guid]::NewGuid().ToString('N'))"
    $promptFile = Join-Path $statePath "$runTag.prompt.md"
    $outputFile = Join-Path $statePath "$runTag.output.md"
    Write-Utf8File $promptFile $Prompt

    # Which login runs this session: the first one not on cooldown (callers only get here when
    # the provider is usable; the primary is the fallback so a session is always attributable).
    $account = Get-ReadyAccount $Provider
    if ($null -eq $account) { $account = @(Get-ProviderAccounts $Provider)[0] }

    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$runner`"",
                 "-Provider", $Provider, "-Mode", $Mode, "-PromptFile", "`"$promptFile`"",
                 "-WorkDir", "`"$WorkDir`"", "-OutputFile", "`"$outputFile`"")
    foreach ($d in $ExtraWritableDirs) { if ($d) { $argList += @("-ExtraWritableDirs", "`"$d`"") } }
    if ($CodexReasoning) { $argList += @("-CodexReasoning", $CodexReasoning) }
    if ($account.codexHome) { $argList += @("-CodexHome", "`"$($account.codexHome)`"") }
    if ($ConflictSession) { $argList += "-ConflictSession" }
    if ($ExpertSession) {
        $argList += "-ExpertSession"
        if (-not $ExpertModel) { $ExpertModel = if ($Provider -eq 'claude') { $ClaudeExpertModel } else { $CodexExpertModel } }
        if ($ExpertModel) { $argList += @("-ExpertModel", "`"$ExpertModel`"") }
    }
    if ($CopilotModel) { $argList += @("-CopilotModel", "`"$CopilotModel`"") }
    if ($script:AgentShellCommands) { $argList += @("-ShellCommands", "`"$($script:AgentShellCommands)`"") }
    if ($script:AgentExtraDirs) { $argList += @("-ExtraDirs", "`"$($script:AgentExtraDirs)`"") }
    if ($script:AgentSandboxWritableDirs) { $argList += @("-SandboxWritableDirs", "`"$($script:AgentSandboxWritableDirs)`"") }

    # Durable "launch intent" record, written BEFORE the child process exists. A crash between
    # "process launched" and "ownership record written" used to leave a live, completely
    # unrecorded worker that Get-LiveWorkerForIssue/Invoke-Recovery had no way to see at all. This
    # placeholder (pid 0, meaning "launch attempted, outcome unknown") closes almost all of that
    # gap: it is on disk before Start-Process is even called, so recovery always finds a record
    # once a launch has been attempted. The one remaining sliver -- a crash in the instant between
    # this write and Start-Process actually creating the process, or between Start-Process
    # returning and the pid update just below -- cannot be closed without OS-level process
    # tracking beyond PID/StartTime (documented as a known limitation); readers of this file
    # (Get-LiveWorkerForIssue, Invoke-Recovery) treat a pid <= 0 as "cannot confirm dead" and fail
    # closed rather than guessing.
    $workerFile = Join-Path $statePath "$Tag.worker.json"
    try {
        [pscustomobject]@{ pid = 0; startTime = 0 } | ConvertTo-Json | Set-Content -Path $workerFile -Encoding ascii -ErrorAction Stop
    } catch {
        Write-Log "[$Tag] could not write the launch-intent record ($($_.Exception.Message)); not starting $Provider"
        return [pscustomobject]@{ Ok = $false; TimedOut = $false; Exit = -1; Output = ""; Unsafe = $true }
    }

    # Get-RecentSessions parses this line ("in <dir>, timeout"); the account goes after that.
    Write-Log "[$runTag] launching $Provider ($Mode) in $WorkDir, timeout $TimeoutMinutes min$(if ($account.key -ne $Provider) { ", account $($account.label)" })$(if ($ExpertSession) { ', expert model=' + $(if ($ExpertModel) { $ExpertModel } else { 'provider default' }) + ', effort=medium, permissions=full' })"
    $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $statePath "$runTag.stdout.txt") -RedirectStandardError (Join-Path $statePath "$runTag.stderr.txt")

    # Now that a real process exists, upgrade the record with its actual identity so liveness can
    # be confirmed by PID+StartTime instead of just "a launch was attempted". If this write fails,
    # the record is stuck at pid 0 (unconfirmed) and callers must not trust anything this worker
    # produced: fail closed rather than validate/push/merge against a process we can no longer
    # positively identify.
    # The deadline travels with the record: the timeout below only exists inside THIS supervisor
    # process, so a worker that outlives a supervisor restart used to be waited on with no limit
    # at all. Get-LiveWorkerForIssue enforces this field on any later supervisor.
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes).ToUniversalTime().ToString("o")
    try {
        [pscustomobject]@{ pid = $proc.Id; startTime = $proc.StartTime.Ticks; deadline = $deadline; tag = $Tag } | ConvertTo-Json | Set-Content -Path $workerFile -Encoding ascii -ErrorAction Stop
    } catch {
        Write-Log "[$Tag] could not record the running worker's PID ($($_.Exception.Message)); stopping process $($proc.Id) instead of waiting on a worker whose identity was never durably recorded"
        $killed = Confirm-ProcessTerminated $proc.Id $proc.StartTime.Ticks
        if (-not $killed) {
            Write-Log "[$Tag] could not confirm process $($proc.Id) was terminated after the ownership record failed to write; it may still be running and writing to the worktree"
        }
        return [pscustomobject]@{ Ok = $false; TimedOut = $false; Exit = -1; Output = ""; Unsafe = $true }
    }

    # Sliced wait: identical total budget to a single WaitForExit($TimeoutMinutes * 60 * 1000)
    # call (the kill/timeout trigger point is unchanged), but broken into 20s slices so a
    # heartbeat can be written between them -- including one before the very first slice, so an
    # owner does not wait 20s for the first sign of life. A Write-Live failure is caught and
    # logged here and must never affect $finished or anything below it.
    $budgetMs = $TimeoutMinutes * 60 * 1000
    $sliceMs = 20000
    $elapsedMs = 0
    $finished = $false
    while ($true) {
        $lastAction = [pscustomobject]@{ at = $null; kind = "unknown"; summary = "" }
        try { $lastAction = Get-LastAgentAction -Provider $Provider -WorkDir $WorkDir -Tag $runTag -CodexHome $account.codexHome } catch { }
        try {
            Write-Live -Tag $Tag -Provider $Provider -StartedAtUtc $proc.StartTime.ToUniversalTime() -Deadline $deadline `
                -LastActionAt $lastAction.at -LastActionKind $lastAction.kind -LastActionSummary $lastAction.summary
        } catch { Write-Log "[$Tag] Write-Live failed: $($_.Exception.Message)" }
        $remainingMs = $budgetMs - $elapsedMs
        if ($remainingMs -le 0) { break }
        $waitMs = [Math]::Min($sliceMs, $remainingMs)
        $finished = $proc.WaitForExit($waitMs)
        $elapsedMs += $waitMs
        if ($finished) { break }
    }
    if (-not $finished) {
        Write-Log "[$runTag] timed out; killing process tree $($proc.Id)"
        $killed = Confirm-ProcessTerminated $proc.Id $proc.StartTime.Ticks
        if (-not $killed) {
            Write-Log "[$Tag] could not confirm process $($proc.Id) was terminated after the timeout kill; leaving its ownership record in place instead of clearing it"
            return [pscustomobject]@{ Ok = $false; TimedOut = $true; Exit = -1; Output = ""; Unsafe = $true }
        }
        Remove-Item $workerFile -Force -ErrorAction SilentlyContinue
        Stop-OrphanedProcesses $Tag
        Stop-LeakedLogHolders $Tag
        return [pscustomobject]@{ Ok = $false; TimedOut = $true; Exit = -1; Output = ""; Unsafe = $false }
    }
    Remove-Item $workerFile -Force -ErrorAction SilentlyContinue
    # The worker is gone, so anything that still holds this supervisor's log files, or any
    # configured tool process whose launcher chain is gone, is a leak from this run: remove it
    # now, while it is a few minutes old, rather than discover it hours later when it blocks a
    # restart.
    Stop-OrphanedProcesses $Tag
    Stop-LeakedLogHolders $Tag
    $exit = if (Test-Path "$outputFile.exit") { [int](Get-Content "$outputFile.exit" | Select-Object -First 1) } else { $proc.ExitCode }
    $output = if (Test-Path $outputFile) { Get-Content -Raw $outputFile -Encoding utf8 } else { "" }
    # 77 is run-agent.ps1's signal for "the provider refused on quota/billing grounds". It is not
    # a result: nothing was attempted, so nothing about the task may be judged from it.
    if ($exit -eq 77) {
        $until = $null
        if (Test-Path "$outputFile.cooldown") {
            try { $until = [datetime]::Parse(([string](Get-Content -Raw "$outputFile.cooldown")).Trim(), $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { $until = $null }
        }
        $why = if (Test-Path "$outputFile.quota") { ([string](Get-Content -Raw "$outputFile.quota")).Trim() } else { "the provider reported no remaining usage allowance" }
        Write-Log "[$runTag] $Provider is out of quota$(if ($account.key -ne $Provider) { " (account $($account.label))" })$(if ($until) { ", resets $($until.ToString('HH:mm'))" }): $why"
        return [pscustomobject]@{ Ok = $false; TimedOut = $false; Exit = $exit; Output = $output; Unsafe = $false; QuotaBlocked = $true; CooldownUntil = $until; QuotaMessage = $why; Account = $account.key }
    }
    Write-Log "[$runTag] $Provider finished with exit $exit ($([int]$output.Length) chars)"
    return [pscustomobject]@{ Ok = ($exit -eq 0); TimedOut = $false; Exit = $exit; Output = $output; Unsafe = $false; QuotaBlocked = $false; CooldownUntil = $null; QuotaMessage = ""; Account = $account.key }
}

function Git-Common-Dir([string]$Worktree) {
    Push-Location $Worktree
    try { $d = (& git rev-parse --git-common-dir 2>$null); if ($d) { return (Resolve-Path $d).Path } } finally { Pop-Location }
    return $null
}

# Paths configured in `worktree.excludePaths` are left out of every agent worktree with a sparse
# checkout. Useful for large vendored material agents never need, or for folders whose file names
# differ only by case (on Windows those collide, so a plain checkout is permanently "dirty" and
# rebase refuses to run).
function Set-WorktreeSparseCheckout {
    if (@($script:WorktreeExcludePaths).Count -eq 0) { return }
    $patterns = @("/*") + @($script:WorktreeExcludePaths | ForEach-Object { "!/$_/" })
    & git sparse-checkout set --no-cone @patterns 2>&1 | Out-Null
}

function New-AgentWorktree([string]$Path, [string[]]$Options, [string]$Commitish) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    $wtArgs = @("worktree", "add", "--no-checkout") + $Options + @($Path)
    if ($Commitish) { $wtArgs += $Commitish }
    & git @wtArgs 2>&1 | Out-Null
    if (-not (Test-Path $Path)) { return $false }
    Push-Location $Path
    try {
        Set-WorktreeSparseCheckout
        & git checkout --quiet 2>&1 | Out-Null
        & git reset --quiet --hard 2>&1 | Out-Null
        $dirty = @(& git status --porcelain).Count
        if ($dirty -gt 0) { Write-Log "Worktree $Path still has $dirty dirty paths after creation" }
    } finally { Pop-Location }
    return $true
}

function Remove-Worktree([string]$Worktree) {
    if (Test-Path $Worktree) {
        & git worktree remove --force $Worktree 2>&1 | Out-Null
        if (Test-Path $Worktree) { Remove-Item -Recurse -Force $Worktree -ErrorAction SilentlyContinue }
    }
    & git worktree prune 2>&1 | Out-Null
}

function Find-PR([string]$Branch) {
    $prs = Invoke-GhJson @("pr", "list", "--repo", $Repository, "--head", $Branch, "--state", "open", "--json", "number,url,isDraft,mergeable,headRefName,headRefOid")
    if ($prs.Count -eq 0) { return $null }
    return $prs[0]
}

function Get-LiveWorkerForIssue([int]$Number) {
    # Every stage that touches this issue's worktree (implement, revise-N, review-N) writes a
    # "$Tag.worker.json" record while its worker process is running (see Invoke-Agent). Checking
    # all of them -- not just the implement one Invoke-Recovery looks at -- is what lets a review
    # cycle notice that a *revision* worker from before a supervisor restart is still alive before
    # it launches another agent or touches the same worktree.
    #
    # Returns $null (no record), or an object { File; Confirmed }: Confirmed=$true means a real,
    # live process was positively identified by PID+StartTime (safe to just wait -- it will exit
    # or hit its own timeout on its own). Confirmed=$false means a record exists but its outcome
    # cannot be told apart from "still running": callers must NOT keep silently skipping this
    # forever on that basis (nothing will ever change it), and must NOT touch the worktree either
    # -- they fail the task for manual attention instead of guessing either way.
    foreach ($f in @(Get-ChildItem -Path $statePath -Filter "issue-$Number-*.worker.json" -ErrorAction SilentlyContinue)) {
        try {
            $info = Get-Content -Raw $f.FullName | ConvertFrom-Json
            $workerPid = [int]$info.pid
            if ($workerPid -le 0) {
                # A launch-intent record (see Invoke-Agent) that was never upgraded with a real
                # PID: the supervisor crashed between recording intent and confirming the process
                # it started. There is no way to tell "nothing was ever launched" apart from "a
                # worker is alive right now with no PID on file" -- fail closed.
                return [pscustomobject]@{ File = $f.FullName; Confirmed = $false }
            }
            $workerStart = [int64]$info.startTime
            $live = Get-Process -Id $workerPid -ErrorAction SilentlyContinue
            if ($live -and $live.StartTime.Ticks -eq $workerStart) {
                # A survivor from a previous supervisor is only waited on while its ORIGINAL
                # deadline (recorded at launch, see Invoke-Agent) has not passed. Past it, the
                # worker is stopped exactly as its own supervisor would have done at that moment,
                # instead of being waited on forever because the process that held the timer died.
                $deadline = $null
                if ($info.deadline) { try { $deadline = [datetime]::Parse([string]$info.deadline, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch { $deadline = $null } }
                if ($deadline -and (Get-Date).ToUniversalTime() -gt $deadline) {
                    Write-Log "Issue #${Number}: worker $($info.tag) (PID $workerPid) outlived its deadline ($($deadline.ToString('o'))) from a previous supervisor run; stopping its process tree"
                    if (Confirm-ProcessTerminated $workerPid $workerStart) {
                        Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
                        continue
                    }
                    return [pscustomobject]@{ File = $f.FullName; Confirmed = $false }
                }
                return [pscustomobject]@{ File = $f.FullName; Confirmed = $true }
            }
            # Confirmed dead (or the PID was recycled by an unrelated process): the record is stale, drop it.
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
        } catch {
            # Cannot confirm this one is dead. Fail closed: treat ownership as unconfirmed.
            return [pscustomobject]@{ File = $f.FullName; Confirmed = $false }
        }
    }
    return $null
}

function Get-WorktreeLastActivity([string]$Worktree) {
    if (-not (Test-Path $Worktree)) { return $null }
    $newest = Get-ChildItem -Path $Worktree -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if ($newest) { return $newest.LastWriteTimeUtc }
    return $null
}

function Get-IssueBranch([object]$Issue, [switch]$Existing) {
    $n = [int]$Issue.number
    $prefix = "agent/issue-$n-"
    $ok = $true
    $st = Load-State $n ([ref]$ok)
    if (-not $ok) { throw "Cannot resolve branch for issue #$n from unreadable state." }
    $saved = [string]$st.branch
    if ($saved -and -not $saved.StartsWith($prefix, [StringComparison]::Ordinal)) { throw "Stored branch does not belong to issue #$n." }
    $checkout = Join-Path $worktreeRoot "issue-$n"
    if (Test-Path -LiteralPath (Join-Path $checkout '.git')) {
        $actual = [string](& git -C $checkout symbolic-ref --quiet --short HEAD 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $actual.StartsWith($prefix, [StringComparison]::Ordinal)) { throw "Issue #$n checkout has no matching task branch; refusing to guess." }
        if ($saved -and $saved -cne $actual) { throw "Issue #$n stored branch and checkout disagree; refusing to replace either." }
        return $actual
    }
    if ($saved) { return $saved }
    if ($Existing) {
        # Legacy tasks may have lost their checkout without having stored branch identity.
        # Bound discovery to this exact issue prefix; never select another task or an ambiguity.
        $prs = @(Invoke-GhJson @('pr','list','--repo',$Repository,'--state','open','--limit','300','--json','headRefName'))
        $matches = @($prs | Where-Object { ([string]$_.headRefName).StartsWith($prefix, [StringComparison]::Ordinal) })
        if ($matches.Count -gt 1) { throw "Multiple open branches belong to issue #$n; explicit recovery required." }
        if ($matches.Count -eq 1) { return [string]$matches[0].headRefName }
        throw "No existing branch identity could be verified for issue #$n; explicit recovery required."
    }
    # A title supplies only the initial name. Once created, identity comes from Git/state/PR.
    $slug = ([string]$Issue.title).ToLowerInvariant() -replace '[^a-z0-9]+', '-' -replace '(^-|-$)', ''
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).TrimEnd('-') }
    return "agent/issue-$([int]$Issue.number)-$slug"
}

function Report-Failure([object]$Issue, [string]$Reason) {
    $n = [int]$Issue.number
    Write-Log "Issue #$n FAILED: $Reason"
    Set-IssueLabels $n @($L.Ready, $L.InProgress, $L.Review, $L.Blocked) @($L.Failed)
    try { Register-FailureOnDashboard $Issue } catch { Write-Log "Issue #${n}: dashboard failure refresh failed: $($_.Exception.Message)" }
    # The retry advice depends on whether there is work to keep. With an open pull request the
    # right label is agent-review (the commits stay and the checks run again from them);
    # agent-ready rebuilds the branch and pays for the whole implementation a second time.
    $retry = "To retry: fix the cause and inspect the existing checkout and pull request. Preserve existing work and use ``$($L.Review)`` for an open pull request. Use ``$($L.Ready)`` only after confirming that a fresh implementation is intended."
    try {
        if (Find-PR (Get-IssueBranch $Issue -Existing)) {
            $retry = "To retry: fix the cause, remove the ``$($L.Failed)`` label and add ``$($L.Review)`` -- not ``$($L.Ready)``. The pull request and its commits are kept and the checks run again from them; ``$($L.Ready)`` would discard the branch and redo the whole implementation."
        }
    } catch {
        $retry = "Branch identity could not be verified. Inspect the existing checkout and pull request before retrying; do not add ``$($L.Ready)`` or recreate the branch. Once the identity is reconciled, resume the preserved pull request with ``$($L.Review)``."
    }
    Comment $n "**Supervisor: this task failed and needs attention.**`n`n$Reason`n`n$retry"
    try { Write-Live -Tag "issue-$n-failed" -Provider "" -StartedAtUtc (Get-Date).ToUniversalTime() -Deadline "" -Role "supervisor" -Step "needs a person" -Summary "issue #$n needs a person: $(($Reason -split "`n")[0])" } catch { }
    $objRef = Get-IssueRefs (Get-Field $Issue.body "Objective")
    if ($objRef.Count -gt 0) {
        $st = Load-State $n
        if (-not $st.escalated) {
            Comment $objRef[0] "Task #$n (`"$($Issue.title)`") failed: $Reason`n`nOther tasks that do not depend on it continue. Tasks blocked by it stay on hold."
            $st.escalated = $true; Save-State $n $st
        }
    }
}

# ----------------------------------------------------------------------------- planning

function Invoke-Planning([object]$Objective) {
    $n = [int]$Objective.number
    Write-Log "Planning objective #${n}: $($Objective.title)"
    # With a trusted-authors allowlist, an objective written or last edited by anyone else is
    # not planned: the planner's tasks would carry commands the host executes. Flagged once by
    # moving it to objective-failed, so it is not re-examined every cycle.
    if (@($TrustedAuthors).Count -gt 0) {
        $identity = Get-IssueIdentity $n
        $actors = @(@{ Role = 'objective author'; Login = $(if ($identity) { [string]$identity.Author } else { '' }) }, @{ Role = 'last editor of the objective'; Login = $(if ($identity) { [string]$identity.Editor } else { '' }) })
        $authority = Test-AcceptanceAuthority -TrustedAuthors $TrustedAuthors -SelfLogin $script:selfLogin -Actors $actors
        if (-not $authority.Trusted) {
            Write-Log "Objective #${n} not planned: $($authority.Reason)"
            Set-IssueLabels $n @($L.Objective) @($L.ObjectiveFailed)
            Comment $n "**Supervisor: this objective was not planned** because $($authority.Reason). Only objectives from trusted authors are planned (``acceptance.trustedAuthors`` in the supervisor configuration). A trusted maintainer can re-file it or add the author to the list, then relabel it ``$($L.Objective)``."
            return
        }
    }
    try { Write-Live -Tag "issue-$n-plan-setup" -Provider $PlannerProvider -StartedAtUtc (Get-Date).ToUniversalTime() -Deadline "" -Role "supervisor" -Step "planning setup" -Summary "preparing the planner worktree for objective #$n" } catch { Write-Log "[issue-$n-plan-setup] Write-Live failed: $($_.Exception.Message)" }

    # If planning was interrupted after creating some/all task issues but before the objective's
    # label moved to objective-planned, this objective is still labelled 'objective' and would be
    # re-planned from scratch, creating duplicate task issues. Detect that first.
    $existingResult = Find-ExistingTaskIssues $n
    if (-not $existingResult.Ok) {
        # Invoke-GhJson (and a plain empty result) cannot be told apart from "the search
        # genuinely found nothing", so a transient gh/API failure here must NOT fall through to
        # creating issues -- that would recreate tasks the failed search simply couldn't see.
        Write-Log "Objective #${n}: could not check for already-created task issues (gh search failed); deferring planning to the next cycle instead of risking duplicate task issues"
        $script:planningDeferred = $true
        return
    }
    $existing = $existingResult.Issues
    if ($existing.Count -gt 0) {
        Write-Log "Objective #$n already has $($existing.Count) task issue(s) referencing it; resuming instead of re-planning (an earlier planning run was likely interrupted)"
        $objState = Load-State $n
        $objState.children = @($existing | ForEach-Object { [int]$_.number })
        Save-State $n $objState
        Set-IssueLabels $n @($L.Objective) @($L.ObjectivePlanned)
        $list = ($existing | Sort-Object number | ForEach-Object { "- #$($_.number) $($_.title)" }) -join "`n"
        Comment $n "Supervisor: found $($existing.Count) task issue(s) already referencing this objective, so an earlier planning run was likely interrupted before it finished. Resuming from the existing tasks instead of creating duplicates:`n`n$list"
        return
    }

    Comment $n "Supervisor: planning started with ``$PlannerProvider``. The plan will be posted here, with one issue per task."

    $planTree = Join-Path $worktreeRoot "planner"
    & git fetch origin main --quiet
    if (Test-Path $planTree) {
        Push-Location $planTree
        try {
            Set-WorktreeSparseCheckout
            & git checkout --quiet --detach origin/main 2>&1 | Out-Null
            & git reset --quiet --hard 2>&1 | Out-Null
            & git clean -fdq 2>&1 | Out-Null
        } finally { Pop-Location }
    }
    else { New-AgentWorktree $planTree @("--detach") "origin/main" | Out-Null }

    $prompt = Fill-Template "planner" @{ REPOSITORY = $Repository; OBJECTIVE_NUMBER = $n; OBJECTIVE_TITLE = $Objective.title; OBJECTIVE_BODY = [string]$Objective.body; LESSONS = (Get-LessonsSection) }
    $run = Invoke-Agent -Provider $PlannerProvider -Mode readonly -Prompt $prompt -WorkDir $planTree -Tag "objective-$n-plan" -TimeoutMinutes $PlannerTimeoutMinutes
    try { Write-Live -Tag "issue-$n-plan-teardown" -Provider $PlannerProvider -StartedAtUtc (Get-Date).ToUniversalTime() -Deadline "" -Role "supervisor" -Step "planning teardown" -Summary "processing the planner result for objective #$n" } catch { Write-Log "[issue-$n-plan-teardown] Write-Live failed: $($_.Exception.Message)" }
    if ($run.QuotaBlocked) {
        Register-QuotaBlock $Objective $PlannerProvider $run "planning"
        # The objective keeps its `objective` label, so planning is simply attempted again once
        # the provider is back. Nothing about it has failed.
        return
    }
    $plan = Extract-Json $run.Output
    if (-not $run.Ok -or -not $plan -or -not $plan.tasks -or @($plan.tasks).Count -eq 0) {
        $why = if ($run.TimedOut) { "the planner timed out" } elseif (-not $run.Ok) { "the planner exited with code $($run.Exit)" } else { "the planner did not return a valid plan" }
        Set-IssueLabels $n @($L.Objective) @($L.ObjectiveFailed)
        Comment $n "**Supervisor: planning failed** because $why.`n`nYou can retry by removing the ``$($L.ObjectiveFailed)`` label and adding ``$($L.Objective)`` again, ideally after making the objective more specific."
        return
    }

    $tasks = @($plan.tasks)
    $keyToNumber = @{}
    $created = @()
    foreach ($t in $tasks) {
        $title = "$($t.title)".Trim()
        $goal = "$($t.goal)".Trim()
        $providerRaw = "$($t.provider)".Trim()
        if (-not $title -or -not $goal -or -not $providerRaw) {
            Write-Log "Skipping malformed task '$($t.key)' for objective #${n}: missing a non-empty title, goal, or provider"
            continue
        }
        # depends_on keys must already be in keyToNumber: the planner is required to emit tasks
        # in dependency order (docs/agent-prompts/planner.md: "tasks with no dependency run
        # first"). A key that ISN'T resolvable here -- because its own task was malformed, its
        # `gh issue create` failed, or it's simply unknown -- must not be silently dropped from
        # `depends_on`: that would produce "Blocked by: none" for a task whose real prerequisite
        # never got created, letting it run immediately with a broken/missing dependency.
        $depKeys = @($t.depends_on | Where-Object { $_ } | ForEach-Object { [string]$_ })
        $unresolved = @($depKeys | Where-Object { -not $keyToNumber.ContainsKey($_) })
        if ($unresolved.Count -gt 0) {
            Write-Log "Skipping task '$($t.key)' for objective #${n}: depends on key(s) $($unresolved -join ', ') that were not successfully created, so a correct 'Blocked by' reference cannot be computed"
            continue
        }
        $provider = Normalize-Provider $providerRaw
        # Defaults to "implementer" for a missing or unrecognised role, via the same Get-TaskRole
        # logic that later reads this same field back out of the finished issue body.
        $role = Get-TaskRole "Role: $($t.role)"
        $deps = @($depKeys | ForEach-Object { "#" + $keyToNumber[$_] })
        $blockedBy = if ($deps.Count -gt 0) { $deps -join ", " } else { "none" }
        $owned = Format-OwnedPathsSection -OwnedPaths @($t.owned_paths | Where-Object { $_ } | ForEach-Object { [string]$_ }) -WorktreeRoot $planTree -Rules $script:OwnershipRules
        $checks = @($t.acceptance_checks | ForEach-Object { "- $_" }) -join "`n"
        # Commands the supervisor itself executes on the host before every review (see
        # Invoke-AcceptanceCommands). Kept in a fenced block so the extractor finds exactly
        # these lines and nothing a reviewer or author later writes in comments.
        $cmdLines = @($t.acceptance_commands | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
        # A command the host can never run successfully is kept in the block as a comment (the
        # extractor skips `#` lines) so the defect is visible in the issue, and logged here,
        # rather than becoming six revision rounds later.
        $cmdLines = @($cmdLines | ForEach-Object {
            $resolved = Resolve-AcceptanceCommand $_
            if ($resolved.Rewritten) { Write-Log "Objective #${n}, task '$($t.key)': acceptance command unwrapped from nested powershell -Command: $($resolved.Command)"; $resolved.Command; return }
            $defect = Get-AcceptanceCommandDefect $_
            if ($defect) { Write-Log "Objective #${n}, task '$($t.key)': acceptance command kept as a comment because $defect -- $_"; "# NOT RUNNABLE, disabled by the supervisor because $defect -- original line: $_" } else { $_ }
        })
        $commandsSection = if ($cmdLines.Count -gt 0) { "`n## Acceptance commands`n" + '```powershell' + "`n" + ($cmdLines -join "`n") + "`n" + '```' + "`n" } else { "" }
        $body = @"
Provider: $provider
Reviewer: $(Other-Provider $provider)
Role: $role
Objective: #$n
Blocked by: $blockedBy

## Goal
$goal

## Non-goals
$($t.non_goals)

## Source of truth
$($t.source_of_truth)

## Owned paths
$owned

## Acceptance checks
$checks
$commandsSection
"@
        $label = if ($deps.Count -gt 0) { $L.Blocked } else { $L.Ready }
        $bodyFile = Join-Path $statePath "new-issue.md"
        Write-Utf8File $bodyFile $body
        $r = Invoke-Gh @("issue", "create", "--repo", $Repository, "--title", "$title", "--body-file", $bodyFile, "--label", $label)
        if ($r.Code -ne 0 -or $r.Text -notmatch "/issues/(\d+)") {
            Write-Log "Could not create task issue for $($t.key): $($r.Text)"
            continue
        }
        $num = [int]$Matches[1]
        $keyToNumber[[string]$t.key] = $num
        $created += "- #$num $title (``$provider``, reviewer ``$(Other-Provider $provider)``$(if ($deps.Count -gt 0) { ", after $blockedBy" }))"
    }

    if ($keyToNumber.Count -eq 0) {
        # Every planner task was malformed, had an unresolved dependency, or failed to create.
        # Marking this objective-planned with zero children would leave it stuck forever:
        # nothing would poll it for planning again, and Check-ObjectiveDone can never complete
        # an objective with no children to check.
        Set-IssueLabels $n @($L.Objective) @($L.ObjectiveFailed)
        Comment $n "**Supervisor: planning failed** because none of the planner's tasks could be turned into a usable issue (see the supervisor log for each one's reason).`n`nYou can retry by removing the ``$($L.ObjectiveFailed)`` label and adding ``$($L.Objective)`` again, ideally after making the objective more specific."
        Write-Log "Objective #${n}: planning produced zero usable tasks; marked $($L.ObjectiveFailed)"
        return
    }

    $objState = Load-State $n
    $objState.children = @($keyToNumber.Values | ForEach-Object { [int]$_ })
    Save-State $n $objState
    Set-IssueLabels $n @($L.Objective) @($L.ObjectivePlanned)
    $notes = if ("$($plan.notes)".Trim()) { "`n`n**Planner notes:** $($plan.notes)" } else { "" }
    Comment $n "## Plan`n`n$($plan.summary)$notes`n`n### Tasks`n$($created -join "`n")`n`nI will report here when each task merges and when the whole objective is done."
    Write-Log "Objective #$n planned into $($created.Count) tasks"
}

# ----------------------------------------------------------------------------- implementation

# Restores every generated file (ownership.generatedFiles) that the task does not own and that
# the branch or working tree changed, back to the branch's merge base with origin/main, and
# commits that restore on its own. Build and import tools often rewrite such files
# non-deterministically, so an author's own acceptance command can dirty a file it may not touch;
# the commit-on-behalf sweep would then commit it and the reviewer would block the diff for it.
# New files are left alone (a generated file beside a new owned source is the author's).
# Returns the restored paths.
function Restore-UnownedGeneratedFiles([string]$Worktree, [string[]]$OwnedPaths, [int]$IssueNumber) {
    $restored = @()
    Push-Location $Worktree
    try {
        $base = ([string](& git merge-base origin/main HEAD 2>$null)).Trim()
        if (-not $base) { return $restored }
        $changed = @(& git diff --name-only $base 2>$null | Where-Object { $_ })
        $candidates = @(Select-UnownedGeneratedPaths -Paths $changed -OwnedPaths $OwnedPaths -Patterns $script:OwnershipRules.generatedFiles)
        foreach ($p in $candidates) {
            & git cat-file -e "${base}:$p" 2>$null
            if ($LASTEXITCODE -ne 0) { continue }
            & git checkout $base -- $p 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $restored += $p }
        }
        if ($restored.Count -gt 0) {
            & git add -- @restored 2>&1 | Out-Null
            & git diff --cached --quiet 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                & git commit -q -m "chore(agent): restore generated files this task does not own" 2>&1 | Out-Null
            }
            Write-Log "Issue #${IssueNumber}: restored $($restored.Count) generated file(s) the task does not own to the branch base: $($restored -join ', ')"
        }
    } finally { Pop-Location }
    return $restored
}

function Validate-And-Push([object]$Issue, [string]$Worktree, [string]$Branch, [string]$Provider) {
    Push-Location $Worktree
    try {
        # Generated files the task does not own go back to the branch base before anything is
        # committed on the author's behalf, so the diff a reviewer sees never contains them.
        try {
            $restoredGenerated = @(Restore-UnownedGeneratedFiles -Worktree $Worktree -OwnedPaths @(Get-OwnedPaths ([string]$Issue.body)) -IssueNumber ([int]$Issue.number))
            if ($restoredGenerated.Count -gt 0) {
                $restoredList = ($restoredGenerated | ForEach-Object { '`' + $_ + '`' }) -join ', '
                Comment ([int]$Issue.number) "Supervisor: restored $($restoredGenerated.Count) generated file(s) this task does not own to the branch base before committing on the author's behalf: $restoredList. Nothing for the author or the reviewer to do about them."
            }
        } catch { Write-Log "Issue #$($Issue.number): could not restore unowned generated files: $($_.Exception.Message)" }
        # Stage everything, then look at the index: on Windows `git status` can report
        # line-ending-only "modifications" that normalise away on add.
        # Retry: a git child of the agent may still hold index.lock for a few seconds after exit.
        $gitDir = (& git rev-parse --git-dir 2>$null)
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            $lock = if ($gitDir) { Join-Path $gitDir "index.lock" } else { $null }
            if ($lock -and (Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalSeconds -gt 60) {
                Write-Log "Issue #$($Issue.number): removing stale index.lock"
                Remove-Item $lock -Force -ErrorAction SilentlyContinue
            }
            & git add -A 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { break }
            Write-Log "Issue #$($Issue.number): git add failed (attempt $attempt); retrying"
            Start-Sleep -Seconds 10
        }
        & git diff --cached --quiet 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Issue #$($Issue.number): agent left real uncommitted changes; committing them on its behalf"
            & git commit -q -m "chore(agent): commit changes left in the worktree by the $Provider session" 2>&1 | Out-Null
        }
        $ahead = [int](& git rev-list --count origin/main..HEAD)
        if ($ahead -eq 0) { return "the agent finished without producing any commits" }
        # Whitespace errors are not a reason to fail the task here: Get-MechanicalFailures reports
        # them to the author as a revision before any review. Protected paths are reported there
        # as a revision too; the only hard stops left here are "nothing to publish" and "the push
        # itself failed".
        if ($PrePushCommand) {
            # A generator step (code generation, an import that writes metadata files). Its exit
            # code is logged, never a reason to fail the task: the test gate and the reviewer judge
            # the result. Tests are NOT run here: a failing test at this point would fail the task
            # with no revision and no pull request to resume from.
            $wrapped = "`$ErrorActionPreference = 'Continue'; & { $PrePushCommand }; if (`$LASTEXITCODE) { exit `$LASTEXITCODE } else { exit 0 }"
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($wrapped))
            $pre = Invoke-BoundedCommand "powershell.exe" "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded" $Worktree 600
            if ($pre.TimedOut -or $pre.Code -ne 0) { Write-Log "Issue #$($Issue.number): pre-push command exited $($pre.Code)$(if ($pre.TimedOut) { ' (timed out)' }); publishing anyway" }
            & git add -A 2>&1 | Out-Null
            & git diff --cached --quiet 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { & git commit -q -m "chore(agent): add files generated by the pre-push command" 2>&1 | Out-Null }
        }
        & git push --force --set-upstream origin $Branch 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return "pushing branch ``$Branch`` failed" }
        return $null
    } finally { Pop-Location }
}

function Invoke-Recovery([object]$Issue) {
    # An issue reaches here only by being labelled agent-in-progress AND open at the top of a
    # poll cycle. The atomic startup lock (see the main loop below) guarantees at most one
    # supervisor PROCESS is ever running, so a live supervisor holding this label is always
    # blocked inside the synchronous Invoke-Implementation call that set it, and cannot
    # simultaneously be here polling its own issue -- the supervisor side of this is genuinely
    # stranded. But Invoke-Agent launches the actual worker (claude/codex, via run-agent.ps1) as
    # an INDEPENDENT process tree the supervisor merely waits on; if the supervisor died or was
    # restarted, that worker can still be alive and actively writing to the worktree. Recovering
    # (deleting the worktree, requeuing as agent-ready so a second worker starts on a fresh one)
    # is only safe once that possibility is ruled out.
    $n = [int]$Issue.number
    Write-Log "Issue #$n is labelled ``$($L.InProgress)`` at the start of a poll cycle; checking whether its worker is still alive before recovering"
    try { Write-Live -Tag "issue-$n-recovery" -Provider (Get-Field $Issue.body "Provider") -StartedAtUtc (Get-Date).ToUniversalTime() -Deadline "" -Role "supervisor" -Step "recovery" -Summary "checking the interrupted worker before recovering issue #$n" } catch { Write-Log "[issue-$n-recovery] Write-Live failed: $($_.Exception.Message)" }

    try { $branch = Get-IssueBranch $Issue -Existing } catch { Report-Failure $Issue $_.Exception.Message; return }
    $worktree = Join-Path $worktreeRoot "issue-$n"

    $workerFile = Join-Path $statePath "issue-$n-implement.worker.json"
    if (Test-Path $workerFile) {
        # Any failure in this whole block (unreadable record, or an unexpected error checking/
        # killing the process) must be treated the same as "cannot confirm the worker stopped":
        # report and stop, never fall through to deleting the worktree on an unhandled exception.
        try {
            $info = Get-Content -Raw $workerFile | ConvertFrom-Json
            $workerPid = [int]$info.pid
            if ($workerPid -le 0) {
                # A launch-intent record that was never upgraded with a real PID (see Invoke-Agent):
                # the supervisor crashed between recording intent and confirming the process it
                # started. Cannot tell "nothing was ever launched" from "a worker is alive right now
                # with no PID on file" -- do not guess either way.
                Report-Failure $Issue "the supervisor restarted while this task was in progress, and the worker ownership record (``$workerFile``) shows a launch that was never confirmed (no process id was ever recorded); it cannot tell whether a worker is still running, so this needs manual attention instead of a guess"
                return
            }
            $workerStart = [int64]$info.startTime
            $live = Get-Process -Id $workerPid -ErrorAction SilentlyContinue
            if ($live -and $live.StartTime.Ticks -eq $workerStart) {
                Write-Log "Issue #${n}: worker process $workerPid is still running; stopping its process tree before recovering"
                if (-not (Confirm-ProcessTerminated $workerPid $workerStart)) {
                    Report-Failure $Issue "the supervisor restarted while this task was in progress, and its worker process (PID $workerPid) could not be stopped; recovering could corrupt an in-flight worktree, so this needs manual attention"
                    return
                }
            }
        } catch {
            Report-Failure $Issue "the supervisor restarted while this task was in progress and its worker-process record (``$workerFile``) could not be checked ($($_.Exception.Message)), so it cannot confirm the previous worker has stopped; recovering could let two workers write to the same branch at once"
            return
        }
        Remove-Item $workerFile -Force -ErrorAction SilentlyContinue
    } else {
        # Invoke-Agent now writes its launch-intent record BEFORE Start-Process, so an entirely
        # missing file means either no worker was ever started for this issue (safe), or the
        # supervisor crashed somewhere between labelling the issue agent-in-progress and Invoke-
        # Agent's own first write -- e.g. mid worktree-creation (NOT safe if a git process it spawned
        # is still running there). An absent file cannot tell these apart, so corroborate with the
        # worktree's own activity: anything actually running there keeps touching files, so require
        # a quiet period comfortably longer than that setup window (and than one poll interval)
        # before trusting that nothing is there.
        $quietSeconds = [Math]::Max(300, $PollSeconds * 2)
        $lastActivity = Get-WorktreeLastActivity $worktree
        if ($lastActivity -and ((Get-Date).ToUniversalTime() - $lastActivity).TotalSeconds -lt $quietSeconds) {
            Write-Log "Issue #${n}: no worker record, but the worktree changed less than $quietSeconds second(s) ago; deferring recovery until it goes quiet instead of assuming no worker is running"
            return
        }
    }

    # Salvage before cleanup. A worktree that already holds work -- commits ahead of origin/main,
    # or edits the agent never got to commit -- is the expensive part of the task, and the two
    # common ways to land here with one are (a) the supervisor restarting while the agent was
    # working (its worker is now confirmed stopped above) and (b) a transient gh failure right
    # after the agent finished, which defers "to the next cycle" with the label still on
    # agent-in-progress and nothing else to show for it. In both cases the branch goes through
    # exactly the gate a normal run uses (Validate-And-Push: commit leftovers, the pre-push
    # command, push) and, if it passes, is published for review.
    # Only when it fails validation does the branch get parked and the task redone from scratch.
    if (Test-Path $worktree) {
        $ahead = 0; $dirty = $false
        Push-Location $worktree
        try {
            & git fetch origin main --quiet 2>&1 | Out-Null
            $ahead = [int](& git rev-list --count origin/main..HEAD 2>$null)
            $status = @(& git status --porcelain --untracked-files=all 2>$null | Where-Object { $_ -and ($_ -notmatch '^\?\? \.agent-state/') })
            $dirty = ($status.Count -gt 0)
        } catch { $ahead = 0; $dirty = $false } finally { Pop-Location }
        if ($ahead -gt 0 -or $dirty) {
            $provider = (Get-IssueProviders $Issue).Author
            Write-Log "Issue #${n}: the interrupted worktree holds work ($ahead commit(s) ahead of origin/main$(if ($dirty) { ', plus uncommitted changes' })); validating and publishing it instead of discarding it"
            $problem = Validate-And-Push $Issue $worktree $branch $provider
            if (-not $problem) {
                if (Publish-Implementation $Issue $worktree $branch $provider) {
                    Comment $n "Supervisor: the supervisor was interrupted while ``$provider`` was working on this task, but the work it had produced passed validation, so it was pushed and sent to review rather than redone."
                    Write-Log "Issue #$n salvaged after an interruption: published to review without a second implementation run"
                }
                return
            }
            Write-Log "Issue #${n}: the interrupted work did not pass validation ($problem); parking it and redoing the task"
            $parked = "abandoned/issue-$n-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
            Remove-Worktree $worktree
            & git branch -m $branch $parked 2>&1 | Out-Null
            Comment $n "Supervisor: the work left by an interrupted run did not pass validation ($problem). It was kept on local branch ``$parked`` on the host (not pushed) in case anything in it is worth reusing, and the task is being redone."
        }
    }

    # Clean up any partial worktree/branch first, exactly as a normal retry does. The branch name
    # is deterministic from the issue number and title, so even if the interrupted run had already
    # pushed commits or opened a PR, requeuing as agent-ready safely redoes the work and the
    # existing PR (if any) just receives the new force-pushed commits (see Invoke-Implementation's
    # "pr create already exists" handling).
    Remove-Worktree $worktree
    & git branch -D $branch 2>&1 | Out-Null
    if (Test-Path $worktree) {
        Report-Failure $Issue "the supervisor was interrupted while this task was in progress and the partial worktree at ``$worktree`` could not be cleaned up automatically; retrying would not be safe"
        return
    }
    Set-IssueLabels $n @($L.InProgress) @($L.Ready)
    Comment $n "Supervisor: recovered from an interruption (the supervisor stopped or restarted while ``$(Get-Field $Issue.body 'Provider')`` was working on this task). Cleaned up any partial worktree/branch and requeued it as ``$($L.Ready)``."
    Write-Log "Issue #$n requeued as $($L.Ready) after recovery"
}

function Invoke-Implementation([object]$Issue) {
    $n = [int]$Issue.number
    try { Write-Live -Tag "issue-$n-implementation" -Provider (Get-Field $Issue.body "Provider") -StartedAtUtc (Get-Date).ToUniversalTime() -Deadline "" -Role "supervisor" -Step "implementation setup" -Summary "preparing implementation for issue #$n" } catch { Write-Log "[issue-$n-implementation] Write-Live failed: $($_.Exception.Message)" }
    $fresh = Get-Issue $n
    if (-not $fresh -or $fresh.state -ne "OPEN") { Write-Log "Issue #$n is no longer open; skipping implementation"; return }
    $Issue = $fresh
    $contractFailures = @(Get-TaskContractFailures $Issue.body)
    if ($contractFailures.Count -gt 0) {
        Invoke-Repair $Issue "task contract preflight" ($contractFailures -join "`n") "" ""
        return
    }
    $assigned = (Get-IssueProviders $Issue).Author
    $provider = Get-EffectiveAuthor $Issue
    if (-not $provider) { Write-Log "Issue #${n}: no provider is available for this task; staying queued"; return }
    if ($provider -ne $assigned) {
        # The assigned author is resting for a while and another provider is free, so hand this
        # task over rather than let the queue stall. Persisted to the issue body, because review
        # independence is decided from those fields later and must reflect who actually wrote it.
        # The assigned author becomes the reviewer (it reviews when its quota is back; until then
        # Get-EffectiveReviewer picks another independent provider).
        if (Set-IssueProviders $Issue $provider $assigned) {
            Write-Log "Issue #${n}: ``$assigned`` is resting, so ``$provider`` takes the implementation and ``$assigned`` will review it."
            Comment $n "Supervisor: ``$assigned`` has no allowance left for a while, so ``$provider`` is writing this one and ``$assigned`` will review it when it returns. Independent review is unchanged - only who does which half."
        } else {
            Write-Log "Issue #${n}: wanted to hand the work to ``$provider`` but could not update the issue; leaving it queued"
            return
        }
    }
    if (-not (Require-Command $provider)) { Write-Log "Provider $provider missing; issue #$n stays queued"; return }

    try { $branch = Get-IssueBranch $Issue } catch { Report-Failure $Issue $_.Exception.Message; return }
    $worktree = Join-Path $worktreeRoot "issue-$n"

    $live = Get-LiveWorkerForIssue $n
    if ($live -and $live.Confirmed) { Write-Log "Issue #${n}: a worker process from a previous run is still alive (``$($live.File)``); skipping this cycle instead of starting a second one"; return }
    if ($live -and -not $live.Confirmed) { Report-Failure $Issue "a worker ownership record (``$($live.File)``) exists from a previous run but its outcome could not be confirmed (no live process could be positively identified); this needs manual attention instead of a guess about whether it is safe to start a new worker"; return }

    Set-IssueLabels $n @($L.Ready) @($L.InProgress)
    Comment $n "Supervisor: ``$provider`` started working on this task."

    # A brand-new worktree/branch is about to be created, so any pendingPush flag left over from a
    # previous, now-abandoned review round (see Invoke-Review) no longer refers to anything real.
    # Likewise the round counters and the "last reviewed commit" memory: a rebuilt branch is a new
    # attempt, judged from round 1. Keep the cumulative correction budget across attempts.
    $st = Load-State $n
    $st.branch = $branch
    $st.pendingPush = $false; $st.revisions = 0; $st.reviewFailures = 0
    $st.lastReviewedSha = $null; $st.lastAutoFailureSha = $null; $st.lastVerdict = $null; $st.lastReviewedRound = 0
    $st.lastAutoFailureSignature = $null; $st.blockedHandledSha = $null
    $st.awaitingRevisionBy = $null; $st.revisionInterruptedByQuota = $false; $st.pendingRevision = $null
    $st.restatedRounds = 0; $st.lastBlockingFindings = @(); $st.findingStreaks = @()
    $st.conflictPending = $false; $st.conflictDetail = $null; $st.repairHint = $null
    if (-not (Save-State $n $st)) { Report-Failure $Issue 'Could not persist task branch identity; implementation deferred before recreating work.'; return }

    & git fetch origin main --quiet
    Remove-Worktree $worktree
    & git branch -D $branch 2>&1 | Out-Null
    if (-not (New-AgentWorktree $worktree @("-b", $branch) "origin/main")) { Report-Failure $Issue "could not create a worktree for branch ``$branch``"; return }

    # Task preflight: a hand-written task (a reviewer's follow-up, an owner rewrite) never went
    # through the planner's Format-OwnedPathsSection, so the tests and companion files its owned
    # files imply are missing from ## Owned paths until a review round catches it. Widen
    # deterministically here, against the fresh worktree, before the author reads the body: a
    # free repair that spends no author or review round. Planner tasks are already widened, so
    # nothing changes for them.
    $preflightAdds = @(Get-TaskPreflightAdditions -Body ([string]$Issue.body) -WorktreeRoot $worktree -IssueNumber $n -OwnedPaths @(Get-OwnedPaths ([string]$Issue.body)) -Rules $script:OwnershipRules)
    if ($preflightAdds.Count -gt 0) {
        $widened = Add-OwnedPathsToBody -Body ([string]$Issue.body) -Additions $preflightAdds
        if ($widened -and (Set-IssueBody $n $widened)) {
            $Issue.body = $widened
            $addedList = ($preflightAdds | ForEach-Object { "``$($_.Path)``" }) -join ', '
            Write-Log "Issue #${n}: task preflight added $($preflightAdds.Count) owned path(s): $addedList"
            Comment $n "Supervisor: task preflight added $addedList to ## Owned paths with deterministic auto markers (the tests and companion files the task's own owned files imply), the same widening the planner applies to its tasks. No author or review round was spent."
        } else {
            Write-Log "Issue #${n}: task preflight found $($preflightAdds.Count) missing owned path(s) but could not update the issue body; continuing with the body as written"
        }
    }

    $prompt = Fill-Template (Get-TaskRole $Issue.body) @{ ISSUE_NUMBER = $n; REPOSITORY = $Repository; BRANCH = $branch; ISSUE_BODY = [string]$Issue.body; REVISION_SECTION = ""; LESSONS = (Get-LessonsSection); AGENT_COMMON = (Get-AgentCommonSection) }
    $run = Invoke-Agent -Provider $provider -Mode edit -Prompt $prompt -WorkDir $worktree -Tag "issue-$n-implement" -TimeoutMinutes $ImplementTimeoutMinutes -ExtraWritableDirs @((Git-Common-Dir $worktree)) -CodexReasoning (Get-TaskReasoning ([string]$Issue.body))
    if ($run.QuotaBlocked) {
        # Nothing was implemented, so put the task straight back in the queue exactly as it was.
        # The next Invoke-Implementation rebuilds the worktree and branch from scratch anyway.
        Register-QuotaBlock $Issue $provider $run "implementation"
        Set-IssueLabels $n @($L.InProgress) @($L.Ready)
        return
    }
    if ($run.Unsafe) { Report-Failure $Issue "``$provider``'s worker ownership could not be durably confirmed, so its outcome cannot be trusted; not validating or pushing whatever is in the worktree"; return }
    if ($run.TimedOut) { Write-Log "Issue #${n}: ``$provider`` did not finish within $ImplementTimeoutMinutes minutes; whatever it committed is validated and published, and the review gate takes it from there"; Comment $n "Supervisor: ``$provider`` ran out of time ($ImplementTimeoutMinutes min). Publishing what it produced so the checks and a reviewer can say what is missing, instead of throwing it away." }

    # A human may have closed this issue while the (potentially long) agent call above was
    # running. Re-check before publishing anything: never push, open a PR, or comment a link
    # for a task nobody wants anymore.
    $mid = Get-Issue $n
    if (-not $mid) { Write-Log "Issue #${n}: could not re-check issue state after the agent ran (gh unreachable); leaving the branch unpushed and deferring to the next cycle"; return }
    if ($mid.state -ne "OPEN") {
        Write-Log "Issue #$n was closed while ``$provider`` was working on it; discarding the result instead of publishing a branch or pull request for a closed issue"
        Remove-Worktree $worktree
        & git branch -D $branch 2>&1 | Out-Null
        return
    }

    $problem = Validate-And-Push $Issue $worktree $branch $provider
    if ($problem) {
        if (-not $run.Ok) { $problem = "``$provider`` exited with code $($run.Exit) and $problem" }
        # An empty run (no commits at all) is retried once with the other provider before anyone
        # is asked: it is usually a sandbox hiccup or a provider having a bad session, not a task
        # defect. The second empty run goes to the repair step.
        $st = Load-State $n
        if ($problem -match 'without producing any commits' -and [int]$st.emptyRuns -lt 1) {
            $st.emptyRuns = [int]$st.emptyRuns + 1; Save-State $n $st | Out-Null
            $other = @(Get-OtherProviders $provider | Where-Object { Test-ProviderUsable $_ })
            if ($other.Count -gt 0) { Set-IssueProviders $Issue $other[0] $provider | Out-Null }
            Set-IssueLabels $n @($L.InProgress) @($L.Ready)
            $with = if ($other.Count -gt 0) { " with ``$($other[0])``" } else { "" }
            Comment $n "Supervisor: ``$provider`` finished without producing any commits. Retrying once$with before asking anyone."
            return
        }
        Report-Failure $Issue $problem; return
    }
    try { Write-Live -Tag "issue-$n-push" -Provider $provider -StartedAtUtc (Get-Date).ToUniversalTime() -Deadline "" -Role "supervisor" -Step "push and PR" -Summary "opening the implementation pull request for issue #$n" } catch { Write-Log "[issue-$n-push] Write-Live failed: $($_.Exception.Message)" }
    Publish-Implementation $Issue $worktree $branch $provider | Out-Null
}

# The tail of an implementation once the branch is validated and pushed: open (or find) the
# draft PR, move the issue to agent-review, tell the owner. Shared with Invoke-Recovery so work
# that a restart or a transient gh failure left finished-but-unpublished is published instead of
# thrown away. Returns $true when the issue reached agent-review.
function Publish-Implementation([object]$Issue, [string]$Worktree, [string]$Branch, [string]$Provider) {
    $n = [int]$Issue.number
    $plannedReviewer = (Get-IssueProviders $Issue).Reviewer
    $prBody = "Automated implementation of #$n by ``$Provider``. Reviewer: ``$plannedReviewer``.`n`nCloses #$n`n`n"
    $prBody += Read-Handoff $Worktree
    $prBodyFile = Join-Path $statePath "issue-$n.pr.md"
    Write-Utf8File $prBodyFile $prBody
    $pr = Invoke-Gh @("pr", "create", "--repo", $Repository, "--draft", "--head", $Branch, "--base", "main", "--title", "agent: $($Issue.title)", "--body-file", $prBodyFile)
    if ($pr.Code -eq 0) {
        $prUrl = $pr.Text.Trim()
    } else {
        # A retry after an earlier partial failure can hit "pull request already exists for branch".
        # Find-PR returns the real PR in that case; otherwise pr create genuinely failed.
        $existingPr = Find-PR $Branch
        if (-not $existingPr) {
            # A network or GitHub-side hiccup (a TCP connect timeout to api.github.com, say) is not a
            # failure of the work: the branch is pushed and the worktree still holds it. Left in
            # progress, the next cycle's Invoke-Recovery sees a worktree ahead of origin/main and
            # publishes it.
            if ($pr.Text -match '(?i)dial tcp|connectex|i/o timeout|timed? ?out|TLS handshake|unexpected EOF|no such host|temporarily unavailable|rate limit|API rate|connection reset|HTTP (500|502|503|504)|Bad Gateway|Service Unavailable|Gateway Time') {
                Write-Log "Issue #${n}: pr create failed on a transient GitHub/network error ($(($pr.Text.Trim() -replace '\s+', ' '))); leaving the task in progress so the next cycle's recovery publishes the pushed branch"
                return $false
            }
            Report-Failure $Issue "the branch was pushed but the pull request could not be created: $($pr.Text)"; return $false
        }
        $prUrl = $existingPr.url
        Write-Log "Issue #${n}: pr create failed (likely already exists); reusing existing PR $prUrl"
    }

    Set-IssueLabels $n @($L.InProgress) @($L.Review)
    Comment $n "Supervisor: ``$Provider`` finished. Pull request: $prUrl`n`nNext: independent review by ``$plannedReviewer`` (or the first other provider with quota left)."
    return $true
}

# ----------------------------------------------------------------------------- review and merge

function Unblock-Dependants([int]$ObjectiveNumber) {
    foreach ($b in Get-IssuesWithLabel $L.Blocked 50) {
        $objRef = Get-IssueRefs (Get-Field $b.body "Objective")
        if ($objRef.Count -eq 0 -or $objRef[0] -ne $ObjectiveNumber) { continue }
        $blockers = Get-IssueRefs (Get-Field $b.body "Blocked by")
        $open = @()
        $unknown = $false
        foreach ($num in $blockers) {
            $i = Get-Issue $num
            # A failed read must NOT silently count as "not open": that would unblock a task
            # whose prerequisite is actually still open (or its true state is simply unknown).
            if (-not $i) { $unknown = $true; continue }
            if ($i.state -eq "OPEN") { $open += $num }
        }
        if ($unknown) { Write-Log "Issue #$($b.number): could not confirm the state of every blocker this cycle; deferring the unblock decision"; continue }
        if ($open.Count -eq 0) {
            Set-IssueLabels ([int]$b.number) @($L.Blocked) @($L.Ready)
            Comment ([int]$b.number) "Supervisor: all prerequisites merged; this task is now queued."
            Write-Log "Unblocked issue #$($b.number)"
        }
    }
}

function Check-ObjectiveDone([int]$ObjectiveNumber) {
    $obj = Get-Issue $ObjectiveNumber
    if (-not $obj -or $obj.state -ne "OPEN") { return }
    $objState = Load-State $ObjectiveNumber
    $children = @()
    $unknownChild = $false
    if ($objState.children) {
        foreach ($c in @($objState.children)) {
            $i = Get-Issue ([int]$c)
            # Same reasoning as Unblock-Dependants: a failed read must not silently drop a
            # child from consideration, or a still-open child whose read happened to fail
            # could make the objective look complete when it is not.
            if (-not $i) { $unknownChild = $true; continue }
            $children += $i
        }
    } else {
        $found = Find-ExistingTaskIssues $ObjectiveNumber
        if (-not $found.Ok) { Write-Log "Objective #${ObjectiveNumber}: could not recover children state (gh search failed); will retry next cycle"; return }
        $children = $found.Issues
    }
    if ($unknownChild) { Write-Log "Objective #${ObjectiveNumber}: could not confirm the state of every child task this cycle; deferring the completion check"; return }
    if ($children.Count -eq 0) { return }
    $openChildren = @($children | Where-Object { $_.state -eq "OPEN" })
    if ($openChildren.Count -eq 0) {
        Set-IssueLabels $ObjectiveNumber @($L.ObjectivePlanned) @($L.ObjectiveDone)
        Comment $ObjectiveNumber "## Done`n`nAll $($children.Count) tasks for this objective have been reviewed and merged into ``main``. Open a new ``objective`` issue for the next thing you want built."
        Invoke-Gh @("issue", "close", "$ObjectiveNumber", "--repo", $Repository) | Out-Null
        Write-Log "Objective #$ObjectiveNumber complete"
    } else {
        $failed = @($openChildren | Where-Object { @($_.labels | ForEach-Object { $_.name }) -contains $L.Failed })
        $active = @($openChildren | Where-Object { @($_.labels | ForEach-Object { $_.name }) -notcontains $L.Failed })
        if ($failed.Count -gt 0 -and $active.Count -eq 0) {
            $st = Load-State $ObjectiveNumber
            if (-not $st.escalated) {
                Comment $ObjectiveNumber "**Supervisor: this objective is stuck.** Remaining tasks all failed or are blocked by failed tasks: $(($failed | ForEach-Object { "#$($_.number)" }) -join ', '). Read their comments to see why."
                $st.escalated = $true; Save-State $ObjectiveNumber $st
            }
        }
    }
}

function Invoke-Reconciliation {
    # Unblock-Dependants and Check-ObjectiveDone are otherwise only called once, in-line, right
    # after a merge that just happened in this same process. Either can defer instead of acting
    # on a transient `gh` read failure (see their own comments above); nothing else ever revisits
    # that objective to retry the deferred decision -- and if the supervisor restarts between the
    # merge and that retry, the in-memory trigger that would have called them again never
    # happens at all. Re-running both for every currently-planned objective, every cycle, closes
    # that gap: the retry is driven purely by GitHub label state, so it also covers a
    # dependant/objective left stuck across a restart, not just within one supervisor's lifetime.
    try { Write-Live -Tag "reconciliation" -Provider "" -StartedAtUtc (Get-Date).ToUniversalTime() -Deadline "" -Role "supervisor" -Step "reconciliation" -Summary "checking blocked tasks and completed objectives" } catch { Write-Log "[reconciliation] Write-Live failed: $($_.Exception.Message)" }
    foreach ($o in @(Get-IssuesWithLabel $L.ObjectivePlanned 20)) {
        $on = [int]$o.number
        Unblock-Dependants $on
        Check-ObjectiveDone $on
    }
}


function Invoke-Review([object]$Issue) {
    $n = [int]$Issue.number
    try { Write-Live -Tag "issue-$n-review-supervisor" -Provider (Get-Field $Issue.body "Reviewer") -StartedAtUtc (Get-Date).ToUniversalTime() -Deadline "" -Role "supervisor" -Step "merge/export" -Summary "checking issue #$n before review and merge" } catch { Write-Log "[issue-$n-review-supervisor] Write-Live failed: $($_.Exception.Message)" }
    $fresh = Get-Issue $n
    if (-not $fresh -or $fresh.state -ne "OPEN") { Write-Log "Issue #$n is no longer open; skipping review"; return }
    $Issue = $fresh
    $providers = Get-IssueProviders $Issue
    $author = $providers.Author

    $worktree = Join-Path $worktreeRoot "issue-$n"
    try { $branch = Get-IssueBranch $Issue -Existing } catch { Report-Failure $Issue $_.Exception.Message; return }
    $pr = Find-PR $branch
    if (-not $pr) { Report-Failure $Issue "no open pull request found for branch ``$branch``"; return }
    if (-not (Test-Path $worktree)) {
        & git fetch origin $branch --quiet
        if (-not (New-AgentWorktree $worktree @() $branch)) { Report-Failure $Issue "could not recreate the worktree for review"; return }
    }

    # A revise-round worker (launched further down, tag "issue-$n-revise-$round") is an
    # independent process the supervisor only waits on synchronously; if the supervisor died or
    # restarted while that wait was blocking, the worker can still be alive and actively writing
    # to this exact worktree. Recovery for the agent-in-progress label (Invoke-Recovery) never
    # sees this case because the issue stays labelled agent-review throughout a revision, so it
    # has to be checked here too, before touching the worktree or launching another agent.
    $live = Get-LiveWorkerForIssue $n
    if ($live -and $live.Confirmed) { Write-Log "Issue #${n}: a worker process from a previous run is still alive (``$($live.File)``); skipping this cycle instead of reviewing or revising against a worktree it may still be writing to"; return }
    if ($live -and -not $live.Confirmed) { Report-Failure $Issue "a worker ownership record (``$($live.File)``) exists from a previous run but its outcome could not be confirmed (no live process could be positively identified); this needs manual attention instead of skipping this issue forever on a guess"; return }

    $stOk = $true
    $st = Load-State $n ([ref]$stOk)
    if (-not $stOk) {
        Report-Failure $Issue "the local task state file could not be read (it may have been corrupted by an interrupted write); whether a revision push is still owed to the pull request cannot be confirmed, so this needs manual attention instead of a guess"
        return
    }
    if (-not $st.branch) {
        $st.branch = $branch
        if (-not (Save-State $n $st)) { Report-Failure $Issue 'Could not persist task branch identity; review deferred.'; return }
    }
    if ($st.pendingPush) {
        # A revision round was started (the flag is set BEFORE the revision worker is even
        # launched -- see below) and its result was never confirmed pushed: either the worker is
        # still running (ruled out by the live-worker check above, which always runs first), it
        # finished but a transient `gh` failure hit the re-check right after, or the supervisor
        # itself stopped/restarted at any point in between. Until the push below lands, the remote
        # PR still shows the OLDER, already-rejected code; reviewing the local worktree now and
        # approving it would merge that stale remote code instead of what was actually reviewed.
        # Retry the push first and let the next cycle do the actual review.
        Write-Log "Issue #${n}: a previous revision was not confirmed pushed; retrying the push before requesting another review"
        $problem = Validate-And-Push $Issue $worktree $branch $author
        if ($problem) { Report-Failure $Issue "a previous revision could not be pushed: $problem"; return }
        $st.pendingPush = $false; $st.awaitingRevisionBy = $null; $st.pendingRevision = $null; $st.revisionInterruptedByQuota = $false; Save-State $n $st
        Comment $n "Supervisor: recovered an unpublished revision and pushed it. Back to review."
        return
    }
    if ($null -eq $st.totalRevisionAttempts) {
        $history = if (Test-Path $logPath) { @(Get-Content $logPath) } else { @() }
        $st.totalRevisionAttempts = Get-LegacyRevisionCount $n $st $history
    }
    if ($st.pendingRevision) {
        Invoke-TaskRevision $Issue $st $worktree $branch $author ([int]$st.revisions + 1) $MaxRevisions ([string]$st.pendingRevision.text) ([string]$st.pendingRevision.by) "" (Get-TaskReasoning $Issue.body)
        return
    }
    $reviewer = Get-EffectiveReviewer $Issue
    if (-not $reviewer) { Write-Log "Issue #${n}: no independent reviewer is available (assigned ``$($providers.Reviewer)``); waiting"; return }
    if ($reviewer -ne $providers.Reviewer) { Write-Log "Issue #${n}: assigned reviewer ``$($providers.Reviewer)`` is unavailable; ``$reviewer`` reviews instead (independent of the author ``$author``)" }
    if ($st.conflictPending) {
        # An approved branch that could not be rebased onto main: the author resolves it.
        if (-not (Test-ProviderUsable $author)) { Write-Log "Issue #${n}: conflict resolution waits for ``$author`` (no allowance)"; return }
        $conflictSection = @"

## Merge conflict with main (not a code review)

Your branch was approved, but it no longer merges cleanly into ``origin/main``. Do exactly this
and nothing else: run ``git merge origin/main`` (``origin/main`` is already fetched and up to
date in this worktree; you do not need and cannot run ``git fetch``); resolve every conflict
keeping BOTH the intent of your change and the intent of what landed on main (read the
conflicting hunks with ``git diff`` / ``git ls-files -u`` / ``git cat-file -p``, do not pick a
side blindly; ``git checkout --ours <path>`` / ``--theirs <path>`` are allowed for whole-file
decisions); ``git add`` the resolved files and ``git commit`` -- the result MUST be a real
two-parent merge commit (``git log -1 --format=%P`` shows two hashes). Never reconstruct a merge
by hand as an ordinary commit: that makes every file main changed look like your change to the
reviewer, and the next rebase fails again. Run nothing destructive. Do not refactor, do not
address old review findings. Update ``## Branch`` in the handoff.

The failed automatic rebase said:

``````
$($st.conflictDetail)
``````
"@
        $prompt = Fill-Template (Get-TaskRole $Issue.body) @{ ISSUE_NUMBER = $n; REPOSITORY = $Repository; BRANCH = $branch; ISSUE_BODY = [string]$Issue.body; REVISION_SECTION = $conflictSection; LESSONS = (Get-LessonsSection); AGENT_COMMON = (Get-AgentCommonSection) }
        $run = Invoke-Agent -Provider $author -Mode edit -Prompt $prompt -WorkDir $worktree -Tag "issue-$n-conflict-$([int]$st.revisions + 1)" -TimeoutMinutes $ImplementTimeoutMinutes -ExtraWritableDirs @((Git-Common-Dir $worktree)) -CodexReasoning (Get-TaskReasoning ([string]$Issue.body)) -ConflictSession
        if ($run.QuotaBlocked) { Register-QuotaBlock $Issue $author $run "conflict resolution"; return }
        if ($run.Unsafe) { Report-Failure $Issue "the conflict-resolution worker's ownership could not be confirmed; this needs manual attention"; return }
        $st.conflictPending = $false; $st.conflictDetail = $null; Save-State $n $st | Out-Null
        $problem = Validate-And-Push $Issue $worktree $branch $author
        if ($problem) { Report-Failure $Issue "after ``$author`` merged ``origin/main`` to resolve a conflict, the branch could not be pushed: $problem"; return }
        Comment $n "Supervisor: ``$author`` merged ``origin/main`` into the branch. Back to a fresh review."
        return
    }

    $round = [int]$st.revisions + 1
    $verdictBy = $reviewer
    $verdict = $null
    $reviewedSha = $null
    $reasoning = Get-TaskReasoning ([string]$Issue.body)
    Push-Location $worktree
    try { $currentHead = ([string](& git rev-parse HEAD 2>$null)).Trim() } finally { Pop-Location }

    # Deterministic gate. Anything a script can decide is decided here, for free, instead of
    # spending a paid review round to discover it: a file that does not parse under PowerShell
    # 5.1, stray whitespace, a change that reached outside the paths any task may touch. These
    # were costing entire review rounds, and a reviewer's opinion is not needed to settle them.
    $mech = @(Get-MechanicalFailures $worktree)

    # Apply the active lesson checks to the task contract and the author's added test code
    # before acceptance commands or a paid reviewer are started.  The helper is kept in
    # lessons.ps1 so it can be exercised with fixture text without constructing a worktree.
    $lessonsReadPath = Get-LessonsReadPath
    if ($lessonsReadPath) {
        $lessonDiff = ''
        Push-Location $worktree
        try { $lessonDiff = ((& git diff origin/main...HEAD 2>$null) -join "`n") } finally { Pop-Location }
        $lessonFailures = @(Get-LessonCheckFailures -Lessons (Read-Lessons -Path $lessonsReadPath) -TaskBody ([string]$Issue.body) -DiffText $lessonDiff)
        $mech += $lessonFailures
    }

    # The task's own acceptance commands, run here on the host. Agent sandboxes often cannot
    # spawn the tools a test needs, so neither the author nor the reviewer can reliably observe a
    # test result; the supervisor can, and its transcript is the only evidence either side gets.
    # A failing command goes straight back to the author with the real output and costs no
    # review round; a passing transcript reaches the reviewer as authoritative, so the reviewer
    # never has to ask the author for proof the author cannot produce.
    $acceptanceCommands = @(Get-AcceptanceCommands ([string]$Issue.body))
    $acceptanceReport = ""
    if ($acceptanceCommands.Count -gt 0 -and $mech.Count -eq 0) {
        # Only commands written by trusted authors run on the host (acceptance.trustedAuthors).
        $skipReason = ""
        try {
            $authority = Get-AcceptanceAuthority $Issue
            if (-not $authority.Trusted) { $skipReason = "the acceptance commands were not executed on the host because $($authority.Reason)" }
        } catch { $skipReason = "the acceptance commands were not executed on the host because their authors could not be verified ($($_.Exception.Message))" }
        if ($skipReason) {
            Write-Log "Issue #${n}: $skipReason"
            if (-not $st.untrustedAcceptanceNotified) {
                $st.untrustedAcceptanceNotified = $true; Save-State $n $st | Out-Null
                Comment $n "Supervisor: $skipReason. The review goes ahead and the reviewer judges those checks by reading the change. A trusted maintainer can re-file the task, or add the author to ``acceptance.trustedAuthors``."
            }
        } else {
            Write-Log "Issue #${n}: running $($acceptanceCommands.Count) acceptance command(s) on the host before review"
        }
        $acceptanceResults = @(Invoke-AcceptanceCommands $worktree $acceptanceCommands -SkipReason $skipReason)
        $acceptanceReport = Format-AcceptanceReport $acceptanceResults $worktree
        Write-Utf8File (Join-Path $statePath "issue-$n.acceptance.md") $acceptanceReport
        foreach ($r in $acceptanceResults) {
            if (-not $r.Ok) { $mech += "Acceptance command failed (exit $($r.ExitCode)): ``$($r.Command)```n$($r.Output)" }
        }
        $passed = @($acceptanceResults | Where-Object { $_.Ok }).Count
        Write-Log "Issue #${n}: acceptance commands $passed/$($acceptanceResults.Count) passed"
    }

    # An approval already given for this exact commit is still valid: the merge after it can be
    # deferred by a push race or a gh hiccup ("will retry next cycle"), and the retry used to buy
    # a second full review of a commit the reviewer had just approved.
    $reuseApproval = ($st.lastReviewedSha -and $currentHead -and "$($st.lastReviewedSha)" -eq $currentHead -and "$($st.lastVerdict)" -eq "approve" -and $mech.Count -eq 0)

    # The author's own word comes first: a `## Blocked` section in the handoff means "do not
    # relaunch me, this needs a person". Read before the mechanical verdict so that a blocked
    # author's diagnosis, not the raw check output, is what the owner sees. Acted on once per
    # commit: after the owner fixes the cause and relabels agent-review, the section is still in
    # the handoff, and a second stop on the same commit would loop forever (the older
    # SCOPE-BLOCKED line had exactly that loop).
    $handoffRaw = Read-Handoff $worktree
    $block = Get-HandoffBlock $handoffRaw
    if ($block -and -not ($st.blockedHandledSha -and $currentHead -and "$($st.blockedHandledSha)" -eq $currentHead)) {
        $st.blockedHandledSha = $currentHead; $st.lastReviewedSha = $null; $st.lastAutoFailureSha = $null; $st.lastAutoFailureSignature = $null
        Save-State $n $st | Out-Null
        # An out-of-scope stop that names the files it needs is a rescope, and a rescope is
        # deterministic: widen ## Owned paths with the existing, uncovered files the author named
        # and send it straight back, spending neither a repair session nor the repair budget
        # (the first three rescopes of a task are free, same rule as the repair step's own).
        # Routed through the repair step instead, a "needs <file>, not owned" report can consume
        # the whole repair budget.
        if ("$($block.Reason)" -in @("out-of-scope", "task-body") -and [int]$st.rescopes -lt 3) {
            try {
                $ownedNow = @(Get-OwnedPaths ([string]$Issue.body))
                # The full section, not Get-HandoffBlock's 600-character summary: a list of five
                # files can sit past that cut.
                $blockSection = [regex]::Match([string]$handoffRaw, '(?ims)^\s*##\s*Blocked\s*$(.*?)(?=^\s*##\s|\z)')
                $blockText = if ($blockSection.Success) { $blockSection.Groups[1].Value } else { [string]$block.Detail }
                $named = @(Get-PathsNamedInBlockedReport -Text $blockText -WorktreeRoot $worktree -OwnedPaths $ownedNow -TaskBody ([string]$Issue.body))
                if ($named.Count -gt 0) {
                    $adds = @($named | ForEach-Object { [pscustomobject]@{ Path = $_; Marker = "(auto: named in the author's ## Blocked report)" } })
                    $widened = Add-OwnedPathsToBody -Body ([string]$Issue.body) -Additions $adds
                    if ($widened -and (Set-IssueBody $n $widened)) {
                        $st.rescopes = [int]$st.rescopes + 1
                        $st.revisions = [Math]::Max(0, [Math]::Min([int]$st.revisions, $MaxRevisions - 2))
                        $namedList = ($named | ForEach-Object { '`' + $_ + '`' }) -join ', '
                        $revisionText = "The author stopped with a Blocked report ($($block.Reason)): $($block.Detail)`n`nThe files it named are now in ## Owned paths: $namedList. Continue the same revision from the existing commits: make the change those files need, run the acceptance commands, and replace the Blocked section of the handoff with the normal handoff."
                        $st.pendingRevision = @{ text = $revisionText; by = "task rescope" }
                        $st.awaitingRevisionBy = (Get-IssueProviders $Issue).Author
                        Save-State $n $st | Out-Null
                        Comment $n "Supervisor: the author reports it cannot finish (**$($block.Reason)**) and names the files it needs; added $namedList to ## Owned paths and sending it straight back to continue. No repair session or review round was spent."
                        return
                    }
                }
            } catch { Write-Log "Issue #${n}: free rescope from the ## Blocked report failed ($($_.Exception.Message)); falling back to the repair step" }
        }
        Invoke-Repair $Issue "the author reports it cannot finish ($($block.Reason))" "The author reports it cannot finish, and the supervisor believes it rather than relaunching it. Reason: **$($block.Reason)** -- $($block.Detail)`n`nNo revision or review round was spent on this." $worktree $branch
        return
    }

    if ($mech.Count -gt 0) {
        $verdictBy = "automatic pre-review checks"
        # Failures the author cannot change go to the owner at once, classified, and cost no
        # author session: the host's port, the host's permissions, a task-body command that does
        # not parse. Sent to the author instead, one such failure consumed six author sessions.
        $unfixable = @()
        foreach ($f in $mech) { $c = Get-FailureClass $f; if ($c) { $unfixable += "**$c**`n`n$f" } }
        if ($unfixable.Count -gt 0) {
            $st.lastReviewedSha = $null; $st.lastAutoFailureSha = $null; $st.lastAutoFailureSignature = $null
            Save-State $n $st | Out-Null
            # The nested-command defect has a deterministic repair; everything else goes to the
            # repair step, which decides between rewriting the task and asking a person.
            if (@($mech | Where-Object { $_ -match 'Lesson L-001' }).Count -gt 0 -and (Repair-NestedAcceptanceCommands $Issue)) {
                Write-Log "Issue #${n}: rewrote nested acceptance commands in the issue body; the checks run again next cycle"
                return
            }
            Invoke-Repair $Issue "the pre-review checks failed for a reason the author cannot change" "The automatic pre-review checks failed for a reason no revision by the author can change, so no author session was spent:`n`n$(($unfixable | ForEach-Object { '- ' + $_ }) -join "`n`n")" $worktree $branch
            return
        }
        # No progress means no next round -- and "progress" is judged on the FAILURE, not on the
        # commit. If the previous round was also stopped here with the same failure signature
        # (Get-FailureSignature: the check output with shas, times and durations blanked), the
        # author either cannot fix it or did not understand it; another revision session would
        # spend the author's allowance to arrive at the same place, whether or not it commits
        # something cosmetic along the way. The same-commit rule is kept as the trivial case of
        # the same thing.
        # ...but only when a revision session actually ran since that record was written. A
        # revision cut short by the author's quota (see the QuotaBlocked branch below) never
        # touched the branch, so an unchanged result after it says nothing about the author;
        # without this exception a task paused on quota is failed seconds later on the very same
        # commit and its implementation redone from scratch.
        $signature = Get-FailureSignature $mech
        $sameCommit = ($st.lastAutoFailureSha -and $currentHead -and "$($st.lastAutoFailureSha)" -eq $currentHead)
        $sameFailure = ($st.lastAutoFailureSignature -and $signature -and "$($st.lastAutoFailureSignature)" -eq $signature)
        if (($sameCommit -or $sameFailure) -and -not $st.revisionInterruptedByQuota) {
            # The record that just fired is cleared before escalating: an owner who relabels
            # agent-review after this is buying exactly one more author round on purpose, and
            # without this the still-stored signature would fire again on the first check.
            $st.lastAutoFailureSha = $null; $st.lastAutoFailureSignature = $null
            Save-State $n $st | Out-Null
            $how = if ($sameCommit) { "the author's revision committed nothing, so repeating it would not change the result" } else { "the author's revision moved the branch to ``$currentHead`` but the checks fail in exactly the same way, so it did not address the cause" }
            Invoke-Repair $Issue "the same check failed twice in a row" "The automatic pre-review checks failed again with the same failure as the previous round: $how. Checks that failed:`n`n$(($mech | ForEach-Object { '- ' + $_ }) -join "`n")" $worktree $branch
            return
        }
        $st.lastAutoFailureSha = $currentHead
        $st.lastAutoFailureSignature = $signature
        $mechSummary = (($mech | Select-Object -First 8) -join '; ')
        Write-Log "Issue #${n}: $($mech.Count) mechanical check(s) failed (signature ${signature}: $mechSummary); sending the change back to ``$author`` without asking a reviewer."
        $verdict = [pscustomobject]@{
            verdict  = "request_changes"
            summary  = "Checks the supervisor runs before every review failed, so no reviewer was asked and no review round was spent. Fix these and the change goes to a real review."
            findings = @($mech | ForEach-Object { [pscustomobject]@{ severity = "blocking"; file = ""; issue = $_; fix = "Correct this and commit. The supervisor re-runs these checks before every review round." } })
        }
    } elseif ($reuseApproval) {
        $reviewedSha = $currentHead
        $verdictBy = "$reviewer (round $([int]$st.lastReviewedRound) approval re-used: same commit)"
        Write-Log "Issue #${n}: commit $currentHead was already approved by ``$reviewer`` in round $([int]$st.lastReviewedRound); re-using that approval instead of paying for another review."
        $verdict = [pscustomobject]@{ verdict = "approve"; summary = "The commit approved in round $([int]$st.lastReviewedRound) is unchanged; the merge is retried on that approval."; findings = @() }
    } else {
        Comment $n "Supervisor: review round $round by ``$reviewer`` started."
        # Captured BEFORE the reviewer runs: this is the exact commit whose approval is being
        # sought. Anything that moves the branch afterwards (a rebase, a late revision push)
        # invalidates the approval, and the merge below refuses rather than merging code no
        # reviewer ever saw.
        Push-Location $worktree
        try { $reviewedSha = ([string](& git rev-parse HEAD 2>$null)).Trim() } finally { Pop-Location }

        $st.lastAutoFailureSha = $null
        $st.lastAutoFailureSignature = $null
        # (A `## Blocked` handoff was already acted on above, before the mechanical verdict: an
        # author blocked on a file outside its owned paths would otherwise spend its rounds
        # committing nothing.)
        $handoff = Limit-Text $handoffRaw $ReviewerHandoffChars "handoff"
        $acceptanceSection = if ($acceptanceReport) { $acceptanceReport } else { "(This task lists no ``## Acceptance commands`` block, so nothing was executed. Judge command-style checks from the handoff and the diff; do not fail the change solely because a command's output is not quoted.)" }

        # Follow-up rounds get what changed since the commit this reviewer last read, plus its
        # own previous findings, instead of starting from nothing. Every earlier round re-read the
        # whole diff, AGENTS.md and large parts of the supervisor script to re-discover a change
        # of twenty lines; that repeated discovery, not the size of any one round, is where the
        # review allowance went. The full diff is still available to the reviewer and is asked
        # for again whenever the incremental one does not stand on its own.
        $previousSection = "This is the first review round: read the full diff as described below."
        $previousFile = Join-Path $statePath "issue-$n.review-$($round - 1).md"
        $lastSha = [string]$st.lastReviewedSha
        if ($round -gt 1 -and $lastSha -and $currentHead -and $lastSha -eq $currentHead) {
            # The reviewer already rejected this exact commit and the revision committed nothing.
            # Paying for a second reading of the same commit cannot produce a different verdict.
            Invoke-Repair $Issue "the author's revision committed nothing" "The reviewer rejected commit ``$currentHead`` in round $($round - 1) and the author's revision committed nothing, so the same commit would be reviewed again. Its last verdict is in the pull request: either the findings are wrong or out of scope, or the author cannot act on them." $worktree $branch
            return
        }
        $known = $false; $stat = ""; $incremental = ""
        if ($round -gt 1 -and $lastSha -and (Test-Path $previousFile)) {
            Push-Location $worktree
            try {
                & git cat-file -e "$lastSha^{commit}" 2>$null
                $known = ($LASTEXITCODE -eq 0)
                if ($known) {
                    $stat = ((& git diff --stat $lastSha HEAD 2>$null) -join "`n").Trim()
                    $incremental = ((& git diff $lastSha HEAD 2>$null) -join "`n").Trim()
                }
            } finally { Pop-Location }
            if ($known -and $incremental) {
                $previousText = ([string](Get-Content -Raw $previousFile -Encoding utf8)).Trim()
                $incremental = Limit-Text $incremental $IncrementalDiffChars "incremental diff"
                $previousSection = "This is round $round. Your previous round's verdict is quoted below, followed by the diff between the commit you reviewed then (``$lastSha``) and the current HEAD.`n`nThe author's handoff should contain a ``## Revision response`` table with one line per blocking finding of your previous round: ``finding -> what changed -> why that resolves the requirement``, or ``disputed: <reason>``. Your job on those lines is to verify each one, not to rediscover the finding: for EVERY file named in a previous blocking finding, read that file in full at HEAD (``git show HEAD:<path>`` or open it), not just the incremental hunk -- a patch is told apart from a fix by its context, not by its diff. Then check the new hunks for new defects. What does not count as a fix: a fallback where the behaviour itself was requested; a check at the point of the symptom instead of at its origin; a special case for the instance you named. A finding you consider disputed is resolved only if the author's reason is sound. Files with no previous finding and no incremental hunk need not be re-audited.`n`n### Your previous round`n`n$previousText`n`n### Changed since ``$lastSha```n`n``````n$stat`n``````n`n``````diff`n$incremental`n``````"
            }
        }
        $prompt = Fill-Template "reviewer" @{ AUTHOR = $author; BRANCH = $branch; ISSUE_NUMBER = $n; ISSUE_BODY = [string]$Issue.body; HANDOFF = $handoff; ACCEPTANCE = $acceptanceSection; PREVIOUS_ROUND = $previousSection; LESSONS = (Get-LessonsSection) }
        $run = Invoke-Agent -Provider $reviewer -Mode readonly -Prompt $prompt -WorkDir $worktree -Tag "issue-$n-review-$round" -TimeoutMinutes $ReviewTimeoutMinutes -CodexReasoning $reasoning
        if ($run.QuotaBlocked) {
            # No review took place, so the round is not consumed and reviewFailures is untouched.
            # The issue stays labelled agent-review and is picked up again after the reset.
            Register-QuotaBlock $Issue $reviewer $run "review"
            return
        }
        if ($run.Unsafe) {
            Report-Failure $Issue "the review worker's ownership could not be durably confirmed, so its outcome cannot be trusted; this needs manual attention rather than another automatic attempt"
            return
        }

        # A human may have closed this issue while the (potentially long) review call above was
        # running. Re-check before posting the review, merging, or requesting a revision.
        $mid = Get-Issue $n
        if (-not $mid) { Write-Log "Issue #${n}: could not re-check issue state after the reviewer ran (gh unreachable); deferring to the next cycle"; return }
        if ($mid.state -ne "OPEN") { Write-Log "Issue #$n was closed while ``$reviewer`` was reviewing it; discarding the review instead of posting/merging/revising"; return }

        $verdict = Extract-Json $run.Output
        if (-not $verdict -or -not $verdict.verdict) {
            # No verdict is a property of the reviewer, not of the task: a quota or outage message
            # the parser does not know, an empty reply, a crash. Twice in a row pauses THAT
            # provider for an hour (another reviewer steps in, or the task waits) instead of
            # failing the task (an unrecognised Copilot "exceeded your monthly quota" reply would
            # otherwise fail every task it reviews). The reply's tail is logged so the wording can
            # be added to Get-QuotaBlock.
            $tail = ((([string]$run.Output) -replace '\s+', ' ').Trim())
            if ($tail.Length -gt 240) { $tail = $tail.Substring(0, 240) + "..." }
            $st.reviewFailures = [int]$st.reviewFailures + 1; Save-State $n $st
            Write-Log "Issue #${n}: reviewer ``$reviewer`` returned no verdict (attempt $($st.reviewFailures)); reply was: $tail"
            if ($st.reviewFailures -ge 2) {
                $st.reviewFailures = 0; Save-State $n $st
                Set-ProviderCooldown $reviewer (Get-Date).AddMinutes(60) "returned no verdict twice in a row (last reply: $tail)"
                Write-Log "Issue #${n}: pausing ``$reviewer`` for 60 minutes after two verdict-less replies; the task stays in review for another reviewer or until then"
                Comment $n "Supervisor: ``$reviewer`` replied twice without a verdict (last reply: $tail). This is a reviewer problem, not a task failure: ``$reviewer`` is paused for an hour and the review is retried with whichever reviewer is available. No round was consumed."
            }
            return
        }
        $st.reviewFailures = 0
        # Remembered for the next round's incremental prompt and the no-progress check above.
        # Saved now: the approve path below never writes state, and a restart in between must
        # not lose which commit this verdict belongs to.
        $st.lastReviewedSha = $reviewedSha
        $st.lastVerdict = "$($verdict.verdict)"
        $st.lastReviewedRound = $round
        Save-State $n $st | Out-Null

        # Keep reviewer findings in the main checkout so repeated review mistakes can become
        # durable lessons. This runs only for an actual provider verdict; automatic mechanical
        # pre-review verdicts do not have reviewer JSON to record.
        try {
            . (Join-Path $scriptDir 'lessons.ps1')
            $findingsPath = Join-Path $statePath 'findings.jsonl'
            $priorFindings = @()
            if (Test-Path $findingsPath) {
                foreach ($line in @(Get-Content -Path $findingsPath -ErrorAction SilentlyContinue)) {
                    if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
                    try { $priorFindings += ($line | ConvertFrom-Json) } catch { Write-Log "Issue #${n}: ignoring malformed findings ledger line" }
                }
            }
            $lessons = Read-Lessons -Path (Get-LessonsReadPath)
            $lessonChanged = $false
            $lessonRule = ''
            # Only blocking findings may become rules for every future prompt: a minor nit phrased
            # alike twice must not turn into a "hard rule" reviewers are then told to enforce. And a
            # finding restated in a later round of the SAME task is an unresolved finding, not a
            # mistake agents repeat across tasks, so this task's earlier findings never count as
            # the second occurrence.
            $priorFromOtherTasks = @($priorFindings | Where-Object { [int]$_.task -ne $n })
            foreach ($reviewFinding in @($verdict.findings | Where-Object { "$($_.severity)" -eq "blocking" })) {
                $finding = [PSCustomObject]@{
                    task     = $n
                    pr       = if ($pr.number) { [int]$pr.number } else { '' }
                    round    = $round
                    reviewer = $reviewer
                    file     = if ($reviewFinding.file) { [string]$reviewFinding.file } else { '' }
                    issue    = if ($reviewFinding.issue) { [string]$reviewFinding.issue } else { '' }
                    fix      = if ($reviewFinding.fix) { [string]$reviewFinding.fix } else { '' }
                    rule     = if ($reviewFinding.rule) { [string]$reviewFinding.rule } else { '' }
                }
                $recorded = Add-Finding -Path $findingsPath -Finding $finding
                $outcome = Add-Or-BumpLesson -Lessons $lessons -Finding $finding -PriorFindings $priorFromOtherTasks
                $priorFindings += $recorded
                if ($outcome.Action -eq 'add' -or $outcome.Action -eq 'bump') {
                    $lessonChanged = $true
                    if (-not $lessonRule) { $lessonRule = [string]$outcome.Entry.rule }
                }
            }
            if ($lessonChanged) { Publish-Lessons $lessons $lessonsFilePath "chore(lessons): $lessonRule" $n }
        } catch {
            # Recording is supplementary to review and must never discard a valid verdict.
            Write-Log "Issue #${n}: recording reviewer findings failed: $($_.Exception.Message)"
        }
    }
    $findings = @($verdict.findings | ForEach-Object { "- **$($_.severity)** $(if ($_.file) { "``$($_.file)`` " })$($_.issue) -> $($_.fix)" }) -join "`n"
    $reviewText = "## Review round $round by ``$verdictBy``: **$($verdict.verdict)**`n`n$($verdict.summary)`n`n$(if ($findings) { $findings } else { '_No findings._' })"
    $reviewFile = Join-Path $statePath "issue-$n.review-$round.md"
    Write-Utf8File $reviewFile $reviewText
    Invoke-Gh @("pr", "comment", "$($pr.number)", "--repo", $Repository, "--body-file", $reviewFile) | Out-Null

    if ("$($verdict.verdict)" -eq "approve") {
        $preMerge = Get-Issue $n
        if (-not $preMerge) { Write-Log "Issue #${n}: could not re-check issue state before merging (gh unreachable); deferring to the next cycle"; return }
        if ($preMerge.state -ne "OPEN") { Write-Log "Issue #$n was closed before the approved change could be merged; skipping the merge"; return }
        $localHead = $null
        Push-Location $worktree
        try {
            & git fetch origin main --quiet
            $behind = [int](& git rev-list --count HEAD..origin/main)
            $fresh = Find-PR $branch
            $conflicting = ($fresh -and "$($fresh.mergeable)" -eq "CONFLICTING")
            # Being behind main is fine for a squash merge; only rebase when GitHub reports a real conflict.
            if ($behind -gt 0 -and $conflicting) {
                $rebaseOut = & git rebase --autostash origin/main 2>&1
                if ($LASTEXITCODE -ne 0) {
                    & git rebase --abort 2>&1 | Out-Null
                    $detail = (($rebaseOut | ForEach-Object { [string]$_ }) | Select-Object -Last 6) -join "`n"
                    # Not a reason for a person: the author merges origin/main in its own worktree,
                    # resolves the conflict, and the result goes through a fresh review.
                    $st.conflictPending = $true; $st.conflictDetail = $detail; $st.lastReviewedSha = $null
                    Save-State $n $st | Out-Null
                    Comment $n "Supervisor: approved by ``$verdictBy``, but the branch conflicts with ``main``. Sending it back to ``$author`` to merge ``origin/main`` and resolve the conflict; the result gets a fresh review before merging."
                    return
                }
                & git push --force origin $branch 2>&1 | Out-Null
            }
            $localHead = (& git rev-parse HEAD 2>$null).Trim()
        } finally { Pop-Location }
        # The reviewer read this worktree, not the PR diff directly. Confirm the commit it
        # actually reviewed is the one sitting at the PR's head before merging anything -- this
        # is what stops a stale or not-yet-pushed revision (see the pendingPush handling above)
        # from having a merge performed against older, already-rejected remote code.
        # The approval belongs to the commit the reviewer actually read. If the branch moved after
        # that -- the rebase just above is the normal way it happens -- the approval no longer
        # applies to what would be merged, so a fresh review is required rather than a merge.
        if ($reviewedSha -and $localHead -and $localHead -ne $reviewedSha) {
            Write-Log "Issue #${n}: approved, but the branch moved from the reviewed commit (``$reviewedSha``) to ``$localHead`` after the review (rebase onto main); requesting a fresh review instead of merging code no reviewer saw."
            Comment $n "Supervisor: the branch had to be rebased onto ``main`` after ``$verdictBy`` approved it, so the approved commit is no longer what would be merged. Running another review over the rebased result before merging."
            return
        }
        $remotePr = Find-PR $branch
        $remoteHead = if ($remotePr) { "$($remotePr.headRefOid)" } else { $null }
        if (-not $localHead -or -not $remoteHead -or $remoteHead -ne $localHead) {
            Write-Log "Issue #${n}: approved, but the reviewed commit (``$localHead``) does not match the pushed PR head (``$remoteHead``); not merging until they match. Will retry next cycle."
            return
        }
        try { Write-Live -Tag "issue-$n-merge" -Provider "" -StartedAtUtc (Get-Date).ToUniversalTime() -Deadline "" -Role "supervisor" -Step "merge/export" -Summary "squash-merging #$($pr.number)" } catch { Write-Log "[issue-$n-merge] Write-Live failed: $($_.Exception.Message)" }
        Invoke-Gh @("pr", "ready", "$($pr.number)", "--repo", $Repository) | Out-Null
        $merge = Invoke-Gh @("pr", "merge", "$($pr.number)", "--repo", $Repository, "--squash")
        if ($merge.Code -ne 0) { Report-Failure $Issue "approved, but merging failed: $($merge.Text)"; return }
        Set-IssueLabels $n @($L.Review) @($L.Done)
        Comment $n "Supervisor: approved by ``$verdictBy`` and merged into ``main``. $($verdict.summary)"
        Invoke-Gh @("issue", "close", "$n", "--repo", $Repository) | Out-Null

        Remove-Worktree $worktree
        & git branch -D $branch 2>&1 | Out-Null
        & git push origin --delete $branch 2>&1 | Out-Null
        Write-Log "Issue #$n merged"
        $objRef = Get-IssueRefs (Get-Field $Issue.body "Objective")
        if ($objRef.Count -gt 0) {
            Comment $objRef[0] "Task #$n (`"$($Issue.title)`") is done and merged. $($verdict.summary)"
            Unblock-Dependants $objRef[0]
            Check-ObjectiveDone $objRef[0]
        }
        return
    }

    # request_changes
    #
    # One stopping rule, and it is a plain count of rounds. Cleverer rules were tried and
    # removed: a fixed ceiling on blocking findings called steady progress "stuck", and
    # comparing finding identity threw on a null from the first round, discarding a review
    # that had already been paid for. A round ceiling is simple, predictable and cannot
    # throw: work that is genuinely converging finishes inside it, and work that is not stops
    # without anybody having to define "converging".
    # Tasks that edit the orchestration itself get a lower ceiling (at most 3): no agent can
    # run the supervisor, their reviews re-read a multi-thousand-line file every round, and
    # the longest review loops observed were all of that kind.
    $ceiling = $MaxRevisions
    try { if (@(Get-OwnedPaths ([string]$Issue.body) | Where-Object { $_ -match 'agent-supervisor\.ps1|run-agent\.ps1' }).Count -gt 0) { $ceiling = [Math]::Min($MaxRevisions, 3) } } catch { }
    if ($round -gt $ceiling) { Invoke-Repair $Issue "the revision ceiling was reached" "The reviewer still requested changes after $ceiling revision rounds$(if ($ceiling -lt $MaxRevisions) { ' (the ceiling is lower for tasks that edit the supervisor scripts)' }). Last review: $($verdict.summary)`n`n$reviewText" $worktree $branch; return }
    # The reviewer's own "this criterion is wrong": a blocking finding whose fix starts with
    # `task-body:` says the task text asks for something the accepted contract forbids or that
    # cannot be built as written (for example a runtime state a decision record rules out by
    # construction, which otherwise costs revision rounds spent disputing it). The author
    # cannot edit the issue, so it goes to the repair step at once, with no revision spent.
    try {
        if ($verdictBy -ne "automatic pre-review checks") {
            $taskBody = @($verdict.findings | Where-Object { "$($_.severity)" -eq "blocking" -and ("$($_.fix)" -match '^\s*task-body:' -or "$($_.issue)" -match '^\s*task-body:') })
            if ($taskBody.Count -gt 0) {
                $list = (($taskBody | ForEach-Object { "- $($_.issue) -> $($_.fix)" }) -join "`n")
                # A task-body finding whose only defect is ownership ("needs file outside owned
                # paths: X") is a rescope, and a rescope is deterministic: when EVERY task-body
                # finding names an existing, uncovered file, widen ## Owned paths and send the
                # whole review to the author as a revision -- no repair session, no budget. A
                # finding that disputes the wording itself still goes to the repair step.
                $ownershipOnly = $false
                $namedByReviewer = @()
                try {
                    if ([int]$st.rescopes -lt 3) {
                        $ownedNow = @(Get-OwnedPaths ([string]$Issue.body))
                        $namedByReviewer = @(Get-PathsNamedInBlockedReport -Text $list -WorktreeRoot $worktree -OwnedPaths $ownedNow -TaskBody ([string]$Issue.body))
                        if ($namedByReviewer.Count -gt 0) {
                            $ownershipOnly = $true
                            foreach ($f in $taskBody) {
                                $text = "$($f.issue) $($f.fix)"
                                $mentions = @($namedByReviewer | Where-Object { $text.IndexOf($_.TrimEnd('/'), [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
                                if ($mentions.Count -eq 0) { $ownershipOnly = $false; break }
                                # A finding that also disputes a decision record or a contract
                                # ("reconcile the decision record's constraint") is a judgement call, not a
                                # rescope: widening the task would let a reviewer override an
                                # accepted design by naming a file. That one keeps the repair step.
                                if ($text -match '(?i)\bADR\b|\bcontract\b|\bforbid|\breconcil|\bdecision record') { $ownershipOnly = $false; break }
                            }
                        }
                    }
                } catch { Write-Log "Issue #${n}: could not classify the task-body findings ($($_.Exception.Message)); using the repair step"; $ownershipOnly = $false }
                if ($ownershipOnly) {
                    $adds = @($namedByReviewer | ForEach-Object { [pscustomobject]@{ Path = $_; Marker = "(auto: named in a reviewer's task-body finding)" } })
                    $widened = Add-OwnedPathsToBody -Body ([string]$Issue.body) -Additions $adds
                    if ($widened -and (Set-IssueBody $n $widened)) {
                        $st.rescopes = [int]$st.rescopes + 1
                        $st.revisions = [Math]::Max(0, [Math]::Min([int]$st.revisions, $MaxRevisions - 2))
                        $st.lastReviewedSha = $null; $st.lastVerdict = $null
                        $namedList = ($namedByReviewer | ForEach-Object { '`' + $_ + '`' }) -join ', '
                        $st.pendingRevision = @{ text = "The reviewer's blocking findings need files the task did not own; they are now in ## Owned paths: $namedList. Address every finding below in one revision.`n`n$reviewText"; by = "task rescope" }
                        $st.awaitingRevisionBy = $author
                        Save-State $n $st | Out-Null
                        Comment $n "Supervisor: the reviewer's task-body finding(s) only needed files the task did not own; added $namedList to ## Owned paths and sending the review to ``$author`` as a revision. No repair session was spent."
                        return
                    }
                }
                Invoke-Repair $Issue "the reviewer reports the task text is defective" "The reviewer reports that the task text itself is defective (an acceptance criterion the accepted contract forbids, or one that cannot be met as written), so no revision was spent:`n`n$list" $worktree $branch
                return
            }
        }
    } catch { Write-Log "Issue #${n}: could not check for task-body findings ($($_.Exception.Message)); continuing" }
    # One more rule, deliberately as simple as the ceiling above and unable to throw (it is
    # wrapped): if an unresolved finding persists alongside any newly discovered defects, twice
    # in a row, the author is patching around the requirement rather than meeting it. Stop and
    # say which finding.
    # Only provider verdicts count; the automatic pre-review gate has its own signature rule.
    try {
        if ($verdictBy -ne "automatic pre-review checks") {
            $currentBlocking = @($verdict.findings | Where-Object { "$($_.severity)" -eq "blocking" } | ForEach-Object { ("$($_.file) $($_.issue)").Trim() } | Where-Object { $_ -ne "" })
            # ($null | ForEach-Object) yields one empty string, and Test-RuleSimilarity refuses an
            # empty argument, which would silently disable this rule.
            $st.findingStreaks = @(Get-FindingStreaks $currentBlocking @($st.findingStreaks))
            $st.restatedRounds = 0
            foreach ($finding in $st.findingStreaks) { $st.restatedRounds = [Math]::Max($st.restatedRounds, [int]$finding.repeats) }
            $st.lastBlockingFindings = $currentBlocking
            Save-State $n $st | Out-Null
            if ([int]$st.restatedRounds -ge 2) {
                $list = (($currentBlocking | ForEach-Object { "- " + $_ }) -join "`n")
                Invoke-Repair $Issue "the same finding was restated three rounds in a row" "The reviewer has asked for the same blocking change(s) in three consecutive rounds and the author's revisions did not resolve them, so another round is unlikely to help:`n`n$list`n`nEither the author cannot make this change (the task or its owned paths are wrong) or the finding is wrong (the task text asks for something the contracts forbid)." $worktree $branch
                return
            }
        }
    } catch { Write-Log "Issue #${n}: could not compare findings across rounds ($($_.Exception.Message)); continuing" }
    Invoke-TaskRevision $Issue $st $worktree $branch $author $round $ceiling $reviewText $verdictBy $acceptanceReport $reasoning
}

# The orchestration files this checkout of the target repository contains (the tool's scripts and
# the prompt templates, when either lives inside the repository), as git pathspecs relative to it.
# A tool installed outside the repository is updated by its owner, not by self-update.
function Get-SelfUpdatePathspecs {
    $specs = @()
    $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
    foreach ($dir in @($scriptDir, $promptDir)) {
        if (-not $dir) { continue }
        $full = [System.IO.Path]::GetFullPath($dir).TrimEnd('\') + '\'
        if ($full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            $specs += ($full.Substring($rootFull.Length) -replace '\\', '/')
        }
    }
    return @($specs | Select-Object -Unique)
}

function Update-Self {
    # At every cycle boundary, fast-forward this checkout to origin/main. If the orchestration code
    # or the prompt templates in it changed, exit so the scheduled-task wrapper restarts us on the
    # new code.
    if ($DryRun -or $Once) { return $false }
    & git fetch origin main --quiet 2>&1 | Out-Null
    $behind = [int](& git rev-list --count HEAD..origin/main 2>$null)
    if ($behind -eq 0) { return $false }
    $specs = @(Get-SelfUpdatePathspecs)
    $changed = if ($specs.Count -gt 0) { @(& git diff --name-only HEAD origin/main -- @specs 2>$null) } else { @() }
    & git pull --ff-only --quiet 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $ahead = [int](& git rev-list --count origin/main..HEAD 2>$null)
        Write-Log "Self-update: git pull --ff-only failed (this checkout is $ahead commit(s) ahead of origin/main and $behind behind; a local commit or a modified tracked file is in the way -- fix it on the host or merged changes never reach the running supervisor); continuing on current code"
        return $false
    }
    Write-Log "Self-update: fast-forwarded $behind commit(s) from origin/main"
    if ($changed.Count -gt 0) {
        # Nothing is in flight at a cycle boundary, so any process still holding this
        # supervisor's log files is a leak -- and it would stop the wrapper from reopening those
        # files to relaunch us. Clear it before exiting, or the restart never comes back.
        Stop-OrphanedProcesses "self-update"
        Stop-LeakedLogHolders "self-update"
        Write-Log "Self-update: orchestration files changed ($($changed -join ', ')); restarting"
        return $true
    }
    return $false
}

# ----------------------------------------------------------------------------- main loop

$script:startedAt = (Get-Date).ToString("o")
$script:githubCalls = 0
$script:versionSha = ""
try { $script:versionSha = ([string](& git -C $root rev-parse --short HEAD 2>$null)).Trim() } catch { }
$script:gh = Require-Command "gh"
if ($null -eq $script:gh) { throw "GitHub CLI 'gh' is required. Install it and run 'gh auth login'." }
& $script:gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "GitHub CLI is not authenticated. Run 'gh auth login'." }
if (-not (Test-Path $runner)) { throw "Missing $runner" }
if (-not (Test-Path -LiteralPath (Join-Path $promptDir "implementer.md"))) { throw "Missing prompt templates in $promptDir" }
Write-Log "Repository $Repository; prompts from $promptDir; state in $statePath; worktrees under $worktreeRoot$(if ($configFile) { "; configuration $configFile" })"

foreach ($name in "claude", "codex", "copilot") {
    $found = Require-Command $name
    if ($found) { Write-Log "Found $name at $found" } elseif ($name -eq "copilot") { Write-Log "copilot not found on PATH; running with claude and codex only (no third-provider fallback)." } else { Write-Log "WARNING: $name not found on PATH." }
}
if ($TestCommand) { Write-Log "Test gate: ``$TestCommand`` (timeout $TestGateTimeoutSeconds s$(if ($TestGateWhenChanged) { ", when a changed path matches $TestGateWhenChanged" }))" }
else { Write-Log "No test gate configured (testGate.command); only acceptance commands and mechanical checks run before review." }
$script:selfLogin = ""
if (@($TrustedAuthors).Count -gt 0) {
    $me = @(Invoke-GhJson @("api", "user"))
    if ($me.Count -gt 0 -and $me[0].login) { $script:selfLogin = [string]$me[0].login }
    Write-Log "Acceptance commands and objectives are accepted only from: $($TrustedAuthors -join ', ') (supervisor account: $(if ($script:selfLogin) { $script:selfLogin } else { 'unknown' }))"
} else {
    Write-Log "WARNING: no trusted-authors allowlist (acceptance.trustedAuthors). Acceptance commands from ANY issue that reaches the queue run on this host."
}
$codexLogins = @(Get-ProviderAccounts "codex")
if ($codexLogins.Count -gt 1) { Write-Log "codex has $($codexLogins.Count) logins, used in this order: $(($codexLogins | ForEach-Object { $_.label }) -join ', ') (reserves under $CodexAccountsDir)" }

if (-not $DryRun) {
    Ensure-Label $L.Objective "5319E7" "Product owner objective; the supervisor will plan it"
    Ensure-Label $L.ObjectivePlanned "8250DF" "Objective split into tasks"
    Ensure-Label $L.ObjectiveDone "0E8A16" "All tasks merged"
    Ensure-Label $L.ObjectiveFailed "B60205" "Planning failed; needs a clearer objective"
    Ensure-Label $L.Blocked "D4C5F9" "Waiting on prerequisite tasks"
    Ensure-Label $L.Ready "0E8A16" "Queued for an agent"
    Ensure-Label $L.InProgress "FBCA04" "An agent is working on it"
    Ensure-Label $L.Review "1D76DB" "Awaiting independent agent review"
    Ensure-Label $L.Done "0052CC" "Merged into main"
    Ensure-Label $L.Failed "B60205" "Needs attention; see comments"
}

New-Item -ItemType Directory -Force -Path $statePath | Out-Null
# An existence-check followed by a separate write (Test-Path/Get-Process/Remove-Item, then
# Set-Content) is not atomic: two supervisors started at the same instant can both pass the
# check before either writes, and both then believe they hold the lock. Opening the lock file
# with FileShare.None is atomic at the OS level -- a second process's open call fails immediately
# if this process (or any other live process) already holds the handle -- and needs no PID
# bookkeeping for staleness: a crashed process's handle is released by the OS on exit, so a
# fresh open here always succeeds once the previous owner is actually gone.
$script:lockStream = $null

# Dashboard-only label results, reused between throttled refreshes (see Test-QueueLabelsStale).
# Initialised here, once, before the loop starts, so the very first cycle still fetches (a
# $null LastFetchedAt always reports stale) and every later cycle has a value to fall back on.
$script:allBlocked = @()
$script:allFailed = @()
$script:allPlanned = @()
$script:queueLabelsFetchedAt = $null
$script:cyclesSinceQueueFetch = 0
if ($DryRun) {
    # A dry run reads and reports; it never acts. Taking the exclusive lock would make it
    # impossible to inspect a running system -- exactly when looking is most useful -- so it
    # deliberately does not compete for the lock (and writes to its own log, see above).
    Write-Log "Dry run: not taking the supervisor lock; the scheduled supervisor, if running, is unaffected."
} else {
    try {
        $script:lockStream = New-Object System.IO.FileStream($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    } catch {
        throw "Could not acquire the exclusive lock on $lockPath (most likely another supervisor is already running; stop it first). Underlying error: $($_.Exception.Message)"
    }
    $pidBytes = [System.Text.Encoding]::ASCII.GetBytes([string]$PID)
    $script:lockStream.SetLength(0)
    $script:lockStream.Write($pidBytes, 0, $pidBytes.Length)
    $script:lockStream.Flush()
    # Whatever the previous instance left behind (it may have exited without its own sweep: a
    # crash, a manual stop, an older version) is a leak by now; clear it so the canonical log
    # files are writable again for the next relaunch and no stale tool process keeps running.
    Stop-OrphanedProcesses "startup"
    Stop-LeakedLogHolders "startup"
    Remove-StaleRotatedLogs
}
try {
    do {
        try {
            $script:githubCalls = 0
            $script:identityCache = @{}
            $didWork = $false
            # Checked every cycle, ahead of everything else: an issue labelled agent-in-progress
            # at this point can only be stranded (see Invoke-Recovery), and leaving it silently
            # in that label would strand it forever.
            $stranded = @(Get-IssuesWithLabel $L.InProgress 10 | Sort-Object number)
            $allObjectives = @(Get-IssuesWithLabel $L.Objective 5 | Sort-Object createdAt)
            $allReviews = @(Get-IssuesWithLabel $L.Review 10 | Sort-Object createdAt)
            $allReady = @(Get-IssuesWithLabel $L.Ready 10 | Sort-Object number)
            # Only for the owner's dashboard; the loop never acts on these three. Throttled to at
            # most every 5th cycle or every 10 minutes since the last fetch, whichever comes
            # first (see Test-QueueLabelsStale) -- unlike stranded/objectives/reviews/ready
            # above, nothing here drives a decision, so the loop reuses the last fetched values
            # between refreshes instead of paying for three gh issue list calls every cycle.
            # A provider whose own quota API says the allowance is spent is put to rest until the
            # reset it reports, before anything is assigned. When Copilot's monthly premium
            # requests once hit 100% with nothing detecting it, three reviews returned nothing and
            # three tasks were failed to a person. Only readers that are authoritative and fresh
            # drive this (Copilot's gh api; the Codex transcript reader can be days stale).
            try { Sync-QuotaCooldowns } catch { Write-Log "Quota cooldown sync failed: $($_.Exception.Message)" }
            $script:cyclesSinceQueueFetch++
            $now = Get-Date
            if (Test-QueueLabelsStale $script:queueLabelsFetchedAt $script:cyclesSinceQueueFetch $now) {
                $script:allBlocked = @(Get-IssuesWithLabel $L.Blocked 20)
                $script:allFailed = @(Get-IssuesWithLabel $L.Failed 20)
                $script:allPlanned = @(Get-IssuesWithLabel $L.ObjectivePlanned 10)
                $script:queueLabelsFetchedAt = $now
                $script:cyclesSinceQueueFetch = 0
            }

            # A provider with nothing left in its allowance is simply not asked again until the
            # moment it said it resets. Work needing the other provider carries on untouched, and
            # nothing is retried in between: no wasted calls, no consumed review rounds, no task
            # marked failed for something that is only the clock.
            # Assigned, not produced by an `if` expression: Windows PowerShell 5.1 unrolls a
            # one-element array coming out of a statement into the bare object, and a
            # PSCustomObject has no .Count there (it is $null, not 1). With exactly one objective
            # pending that made `$objectives.Count -gt 0` false, so the objective was never
            # planned and was reported as "paused on quota" while both providers were ready.
            $objectives = @()
            if (Test-ProviderUsable $PlannerProvider) { $objectives = $allObjectives }
            # A review or task counts as runnable when SOME provider can take it now: the assigned
            # one, or -- for reviews immediately, for authors after -SwapAfterMinutes -- another
            # independent one (see Get-EffectiveReviewer / Get-EffectiveAuthor). Filtering on the
            # assigned provider alone would make the hand-over in Invoke-Implementation unreachable.
            $reviews = @($allReviews | Where-Object { Test-ReviewRunnable $_ })
            $ready = @($allReady | Where-Object { $null -ne (Get-EffectiveAuthor $_) })
            $waiting = ($allObjectives.Count - $objectives.Count) + ($allReviews.Count - $reviews.Count) + ($allReady.Count - $ready.Count)

            $nextAction = if ($stranded.Count -gt 0) { "recover #$($stranded[0].number)" }
                elseif ($reviews.Count -gt 0) { "review #$($reviews[0].number)" }
                elseif ($objectives.Count -gt 0) { "plan #$($objectives[0].number)" }
                elseif ($ready.Count -gt 0) { "implement #$($ready[0].number)" }
                else { "idle" }
            Write-Status @{
                nextAction       = $nextAction
                stranded         = $stranded.Count
                objectivesToPlan = $allObjectives.Count
                reviewsPending   = $allReviews.Count
                tasksReady       = $allReady.Count
                waitingOnQuota   = $waiting
            }
            Write-Dashboard @{ "in-progress" = $stranded; objective = $allObjectives; "objective-planned" = $script:allPlanned; review = $allReviews; ready = $allReady; blocked = $script:allBlocked; failed = $script:allFailed } $nextAction $script:queueLabelsFetchedAt
            if ($DryRun) {
                Write-Log "Dry run: $($stranded.Count) stranded agent-in-progress issue(s), $($objectives.Count) objective(s) to plan, $($reviews.Count) review(s) pending, $($ready.Count) task(s) ready."
                foreach ($s in $stranded) { Write-Log "  stranded  #$($s.number): $($s.title)" }
                foreach ($o in $objectives) { Write-Log "  objective #$($o.number): $($o.title)" }
                foreach ($r in $reviews) { Write-Log "  review    #$($r.number): $($r.title)" }
                foreach ($t in $ready) { Write-Log "  ready     #$($t.number): $($t.title) [$(Get-Field $t.body 'Provider')]" }
            } elseif ($stranded.Count -gt 0) {
                Invoke-Recovery $stranded[0]; $didWork = $true
            } elseif ($reviews.Count -gt 0) {
                Invoke-Review $reviews[0]; $didWork = $true
            } elseif ($objectives.Count -gt 0) {
                # A deferred planning attempt (a failed gh search) is not work: it must wait the
                # full poll interval like an idle cycle, not spin every five seconds against GitHub.
                $script:planningDeferred = $false
                Invoke-Planning $objectives[0]; $didWork = -not $script:planningDeferred
            } elseif ($ready.Count -gt 0) {
                Invoke-Implementation $ready[0]; $didWork = $true
            } else {
                Write-Log "Idle: nothing to plan, implement or review.$(if ($waiting -gt 0) { " ($waiting item(s) paused only until a provider's quota resets.)" })"
                $idleUntil = (Get-Date).AddSeconds($PollSeconds).ToString("HH:mm")
                try { Write-Live -Tag "idle" -Provider "" -StartedAtUtc (Get-Date).ToUniversalTime() -Deadline $idleUntil -Role "supervisor" -Step "idle" -Summary "idle until $idleUntil" } catch { Write-Log "[idle] Write-Live failed: $($_.Exception.Message)" }
            }
            # Self-update at every cycle boundary, busy or idle. Everything above is synchronous
            # (Invoke-Agent waits for its worker; every step persists its state before returning),
            # so nothing is in flight here and a restart is safe. Updating only when idle left the
            # supervisor on stale code for as long as an objective kept its queue busy -- with a
            # six-task chain that can be a whole night -- while the fix for the very loop it was
            # in sat merged on main.
            if (-not $DryRun) { if (Update-Self) { break } }
            if (-not $DryRun) {
                # Runs every cycle, independent of whatever else happened above, so a dependant
                # or objective left stuck by a transient read failure (or by a restart between a
                # merge and its in-line Unblock-Dependants/Check-ObjectiveDone call) is always
                # retried on the next poll instead of only right after a fresh merge.
                Invoke-Reconciliation
            }
        } catch {
            Write-Log "ERROR in cycle: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
            $didWork = $false
        }
        if ($Once) { break }
        if (-not $didWork) { Start-Sleep -Seconds $PollSeconds } else { Start-Sleep -Seconds 5 }
    } while ($true)
} finally {
    # Only the process that opened the handle can be holding it, so disposing it here always
    # releases exactly this run's own lock, never another instance's.
    if ($script:lockStream) {
        $script:lockStream.Dispose()
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
}
