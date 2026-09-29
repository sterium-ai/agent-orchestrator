<#
.SYNOPSIS
Runs one non-interactive agent session (Claude Code, Codex or GitHub Copilot CLI) with a fixed tool policy.

.DESCRIPTION
Invoked by agent-supervisor.ps1 as a child process so the supervisor can enforce a
timeout and kill the whole process tree if the agent hangs. The prompt is read from
-PromptFile and piped through stdin, which avoids command-line quoting limits.
The agent's final message is written to -OutputFile and the process exit code to
"$OutputFile.exit".

Modes:
  edit      may read and write files in the working directory, use git, and run the shell
            commands named in -ShellCommands
  readonly  may only read files, run read-only git commands and the -ShellCommands tools
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet("claude", "codex", "copilot")][string]$Provider,
    [Parameter(Mandatory)][ValidateSet("edit", "readonly")][string]$Mode,
    [Parameter(Mandatory)][string]$PromptFile,
    [Parameter(Mandatory)][string]$WorkDir,
    [Parameter(Mandatory)][string]$OutputFile,
    [string[]]$ExtraWritableDirs = @(),
    [string]$CodexReasoning = "medium",
    # Copilot CLI model. "auto" lets Copilot route (cheap flash models for small jobs) and does
    # not accept --reasoning-effort; a named model gets the same effort level as codex.
    [string]$CopilotModel = "auto",
    # Codex login to use: a CODEX_HOME folder (config, auth.json, sessions). Empty means the
    # default ~/.codex. The supervisor passes a reserve login here when the primary is out of
    # quota (see Get-ProviderAccounts in agent-supervisor.ps1).
    [string]$CodexHome = "",
    # Owner-provided material outside the repository, granted to every provider as extra
    # directories. Semicolon-separated; directories that do not exist are skipped. Agents copy
    # from them, never edit them.
    [string]$ExtraDirs = "",
    # Directories outside the worktree that the project's own tools must be able to write to from
    # a sandboxed Codex edit session (a tool's user-data folder, for example). Semicolon-separated;
    # environment variables are expanded; missing directories are created.
    [string]$SandboxWritableDirs = "",
    # Command names (not full command lines) agents may run through the shell, besides git.
    # Semicolon-separated. Translated to each CLI's own allowlist syntax.
    [string]$ShellCommands = "python;py;powershell",
    # Conflict-resolution session: the author must merge origin/main into its branch. Grants
    # `git merge`, `git ls-files`, `git cat-file` and `git checkout --ours/--theirs` on top of the
    # edit tools -- local commands only; origin/main is already fetched by the supervisor in this
    # worktree, so no network is needed. Without this, #137 (2026-09-18) looped four times:
    # the author "hand-reconstructed" the merge as a single-parent commit, the reviewer then saw
    # all of main's files as out-of-scope changes, and the rebase failed again on the next round.
    [switch]$ConflictSession,
    # Explicitly owner-authorized exceptional writer session; ordinary roles keep their policy.
    [switch]$ExpertSession,
    # Model for an expert session. Empty means the provider's default model.
    [string]$ExpertModel = ""
)

if ($ExpertSession -and ($Mode -ne 'edit' -or $Provider -notin @('claude','codex'))) {
    throw 'ExpertSession requires an edit session with Claude or Codex; reviewers keep their permissions.'
}

$ErrorActionPreference = "Continue"
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
# Agents print UTF-8; decode it correctly and hand the prompt over as UTF-8 too.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Split-List([string]$Text) {
    return @(([string]$Text -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$extraDirList = @(Split-List $ExtraDirs | Where-Object { Test-Path -LiteralPath $_ })
$shellCommandList = @(Split-List $ShellCommands | Where-Object { $_ -match '^[A-Za-z0-9_.\-]+$' })
$sandboxWritableList = @(Split-List $SandboxWritableDirs | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) })

function Resolve-Provider([string]$Name) {
    $override = [Environment]::GetEnvironmentVariable(($Name.ToUpperInvariant() + "_COMMAND"))
    if (-not [string]::IsNullOrWhiteSpace($override)) { return $override }
    # Prefer the .cmd shim: it works regardless of the PowerShell execution policy.
    foreach ($candidate in @("$Name.cmd", "$Name.exe", $Name)) {
        $cmd = @(Get-Command $candidate -ErrorAction SilentlyContinue) | Select-Object -First 1
        if ($cmd) { return [string]$cmd.Source }
    }
    return $null
}

# Providers report an exhausted plan on stdout and then exit non-zero -- indistinguishable, to the
# supervisor, from "the agent tried and did badly" unless the text is inspected. Classifying it
# here is what stops a billing state from consuming a task's revision/review budget. Real wording
# observed from both CLIs:
#   claude: "You've hit your session limit * resets 5:30pm (<local time zone>)"
#   codex : "ERROR: You've hit your usage limit. ... or try again at 7:51 PM."
# Copilot CLI (free plan) observed 2026-09-19: "You have exceeded your monthly quota (Request
# ID: ...)" -- no reset time in the text; the allowance resets on the 1st of the next month.
# Before that wording was known, three tasks (#206-#208) were FAILED as "the reviewer failed
# twice to produce a verdict" instead of pausing the provider.
function Get-QuotaBlock([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $patterns = @(
        'hit your (session|usage|weekly|monthly|daily) limit',
        'usage limit reached',
        'quota (exceeded|exhausted)',
        'rate limit(ed)? exceeded',
        'too many requests',
        'insufficient (credits|quota)',
        'out of credits',
        'purchase more credits',
        'premium requests? (quota|limit|allowance|budget)',
        '(exhausted|exceeded|used up|reached) (your|the) (premium requests?|ai credits?|monthly (usage|allowance))',
        'no (premium requests?|ai credits?) (left|remaining)',
        'monthly (usage|request) (limit|quota) (reached|exceeded)',
        'exceeded your (monthly|weekly|daily) quota',
        'monthly quota'
    )
    # The message must come from a line that matches one of the patterns above, not merely one
    # containing the word "limit": the codex log echoes the whole prompt back, and a task whose
    # own text mentions a limit would otherwise be quoted in full into a GitHub comment.
    #
    # The reset time is parsed from THAT SAME LINE, never from the text as a whole. Issue #13's
    # body quotes both providers' limit messages as test fixtures ("resets 5:30pm", "try again at
    # 7:51 PM"); with the prompt echoed into the codex log, a whole-text search found the fixture
    # first and paused codex until 17:30 the next day three times, while codex's real message said
    # the allowance was back within minutes. Callers should also strip the echoed prompt before
    # calling this (see below), but the per-line rule holds on its own.
    $line = ""
    foreach ($candidate in ($Text -split "`n")) {
        foreach ($p in $patterns) {
            if ($candidate -match $p) { $line = $candidate; break }
        }
        if ($line) { break }
    }
    if (-not $line) { return $null }

    # Both CLIs state when the allowance comes back. Use that exact time rather than guessing with
    # a retry ladder: the whole point is to come back once, when it is actually worth trying.
    $until = $null
    # Two shapes seen in the wild. Same day: "try again at 7:51 PM". A later day carries a date
    # first: "try again at Sep 13th, 2026 12:10 AM" -- which the time-only pattern silently missed,
    # so the supervisor fell back to guessing 30 minutes and then re-hit the same wall every half
    # hour for four hours. Try the dated form first, since the time-only pattern would otherwise
    # match the digits inside the date.
    $dated = [regex]::Match($line, '(?:resets|try again at|retry after|available again at)\s*:?\s*([A-Za-z]{3,9})\s+(\d{1,2})(?:st|nd|rd|th)?,?\s*(\d{4})?[,\s]+(\d{1,2}):(\d{2})\s*([ap]\.?m\.?)?', 'IgnoreCase')
    if ($dated.Success) {
        $monthNames = @{ jan=1; feb=2; mar=3; apr=4; may=5; jun=6; jul=7; aug=8; sep=9; oct=10; nov=11; dec=12 }
        $key = $dated.Groups[1].Value.Substring(0, 3).ToLowerInvariant()
        if ($monthNames.ContainsKey($key)) {
            $hour = [int]$dated.Groups[4].Value
            $minute = [int]$dated.Groups[5].Value
            $ampm = ($dated.Groups[6].Value -replace '\.', '').ToLowerInvariant()
            if ($ampm -eq 'pm' -and $hour -lt 12) { $hour += 12 }
            if ($ampm -eq 'am' -and $hour -eq 12) { $hour = 0 }
            $year = if ($dated.Groups[3].Success) { [int]$dated.Groups[3].Value } else { (Get-Date).Year }
            $day = [int]$dated.Groups[2].Value
            $month = $monthNames[$key]
            if ($day -ge 1 -and $day -le 31 -and $hour -ge 0 -and $hour -le 23 -and $minute -ge 0 -and $minute -le 59) {
                try { $until = Get-Date -Year $year -Month $month -Day $day -Hour $hour -Minute $minute -Second 0 } catch { $until = $null }
            }
        }
    }
    $m = if ($until) { $null } else { [regex]::Match($line, '(?:resets|try again at|retry after|available again at)\s*:?\s*(\d{1,2})(?::(\d{2}))?\s*([ap]\.?m\.?)?', 'IgnoreCase') }
    if ($m -and $m.Success) {
        $hour = [int]$m.Groups[1].Value
        $minute = if ($m.Groups[2].Success) { [int]$m.Groups[2].Value } else { 0 }
        $ampm = ($m.Groups[3].Value -replace '\.', '').ToLowerInvariant()
        if ($ampm -eq 'pm' -and $hour -lt 12) { $hour += 12 }
        if ($ampm -eq 'am' -and $hour -eq 12) { $hour = 0 }
        if ($hour -ge 0 -and $hour -le 23 -and $minute -ge 0 -and $minute -le 59) {
            $now = Get-Date
            $until = Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour $hour -Minute $minute -Second 0
            # A stated time that has already passed today means tomorrow -- unless it passed only
            # minutes ago. Codex reports the reset to the minute, and a launch at 23:43:13 was told
            # "try again at 11:43 PM": that is "now", not "in 24 hours".
            if ($until -le $now.AddMinutes(-10)) { $until = $until.AddDays(1) }
        }
    }
    # A monthly allowance with no stated reset (Copilot) comes back on the 1st of next month.
    if (-not $until -and $line -match '(?i)monthly (quota|usage|allowance|limit)') {
        $now = Get-Date
        $until = (Get-Date -Year $now.Year -Month $now.Month -Day 1 -Hour 0 -Minute 10 -Second 0).AddMonths(1)
    }
    $line = ($line -replace '^\s*ERROR:\s*', '').Trim()
    if ($line.Length -gt 200) { $line = $line.Substring(0, 200).TrimEnd() + "..." }
    return [pscustomobject]@{ Until = $until; Message = $line }
}

$exe = Resolve-Provider $Provider
if (-not $exe) {
    Set-Content -Path "$OutputFile.exit" -Value "127"
    Write-Error "Provider '$Provider' not found on PATH."
    exit 127
}

if (-not (Test-Path $WorkDir)) {
    Set-Content -Path "$OutputFile.exit" -Value "1"
    Write-Error "WorkDir '$WorkDir' does not exist; refusing to run the agent from an unintended directory."
    exit 1
}

$prompt = Get-Content -Raw -Path $PromptFile -Encoding utf8
$exit = 1
Push-Location $WorkDir
try {
    if ($Provider -eq "claude") {
        $shellTools = @($shellCommandList | ForEach-Object { "Bash(${_}:*)" })
        $editTools = @(
            "Read", "Write", "Edit", "MultiEdit", "Glob", "Grep",
            "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)", "Bash(git show:*)",
            "Bash(git add:*)", "Bash(git commit:*)", "Bash(git rm:*)", "Bash(git mv:*)"
        ) + $shellTools
        if ($ConflictSession) { $editTools += @("Bash(git merge:*)", "Bash(git ls-files:*)", "Bash(git cat-file:*)", "Bash(git checkout --ours:*)", "Bash(git checkout --theirs:*)") }
        # Read-only means no edits and no git writes; running the project's own test tools is
        # reading (they write only caches and temp files). Without them a reviewer or the repair
        # step reasons about a red test blind.
        $readTools = @(
            "Read", "Glob", "Grep",
            "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)", "Bash(git show:*)"
        ) + $shellTools
        $claudeDirs = @()
        foreach ($d in $extraDirList) { $claudeDirs += @("--add-dir", $d) }
        if ($ExpertSession) {
            $modelArgs = @()
            if ($ExpertModel) { $modelArgs = @("--model", $ExpertModel) }
            $result = $prompt | & $exe -p --output-format text @modelArgs --effort medium --dangerously-skip-permissions @claudeDirs 2>&1
        } elseif ($Mode -eq "edit") {
            $result = $prompt | & $exe -p --output-format text --permission-mode acceptEdits @claudeDirs --allowedTools @($editTools) 2>&1
        } else {
            $result = $prompt | & $exe -p --output-format text @claudeDirs --allowedTools @($readTools) 2>&1
        }
        $exit = $LASTEXITCODE
        # Strip PowerShell error records that come from stderr so the file holds plain text.
        $text = ($result | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ } }) -join "`n"
        Set-Content -Path $OutputFile -Value $text -Encoding utf8
    } elseif ($Provider -eq "copilot") {
        # GitHub Copilot CLI, same shape as the other two: prompt on stdin (a bare pipe with no
        # -p runs it non-interactively and exits when done; `-p -` would be the literal prompt
        # "-"), -s prints only the agent's reply, --no-ask-user makes any tool that is not
        # pre-allowed a silent denial instead of a prompt nobody can answer. The built-in GitHub
        # MCP server is disabled so the agent cannot reach outside the worktree through the API,
        # matching the other providers. Tool permissions mirror claude's allowlists. Copilot
        # writes real token/premium-request usage to a JSON file; the supervisor reads it for the
        # dashboard. Verified on the host 2026-09-15 (denied write exits 0 with no file; allowed
        # write + git commit works; model "auto" rejects --reasoning-effort).
        $usageFile = "$OutputFile.usage.json"
        Remove-Item $usageFile -Force -ErrorAction SilentlyContinue
        $cpArgs = @("-s", "--no-auto-update", "--no-ask-user", "--disable-builtin-mcps", "-C", $WorkDir, "--usage-output-file", $usageFile)
        # Custom MCP servers from ~/.copilot/mcp-config.json stay enabled; only the built-in
        # GitHub one is off. Their tools are not pre-allowed, so --no-ask-user denies them.
        if ($CopilotModel -and $CopilotModel -ne "auto") {
            $cpArgs += @("--model", $CopilotModel)
            if ($CodexReasoning) { $cpArgs += @("--reasoning-effort", $CodexReasoning) }
        }
        $gitRead = @("shell(git status:*)", "shell(git diff:*)", "shell(git log:*)", "shell(git show:*)")
        $cpShell = @($shellCommandList | ForEach-Object { "shell(${_}:*)" })
        if ($Mode -eq "edit") {
            $cpArgs += "--allow-tool"
            $cpArgs += @("write") + $gitRead + @("shell(git add:*)", "shell(git commit:*)", "shell(git rm:*)", "shell(git mv:*)") + $cpShell
            foreach ($d in $ExtraWritableDirs) { if ($d) { $cpArgs += @("--add-dir", $d) } }
            foreach ($d in $extraDirList) { $cpArgs += @("--add-dir", $d) }
        } else {
            $cpArgs += "--allow-tool"
            $cpArgs += $gitRead
            $cpArgs += @("--deny-tool", "write")
        }
        # Streamed rather than captured into a variable: assigning `& $exe ... 2>&1` to a
        # variable buffers every line until the process exits, so the redirected
        # "<tag>.stdout.txt" (Invoke-Agent's -RedirectStandardOutput of this whole script's
        # process) stayed empty for the run's entire duration and a live reader had nothing to
        # read. Piping into ForEach-Object and writing each line with Write-Output instead sends
        # it straight to this script's own stdout as it arrives, while still collecting the same
        # lines to write to $OutputFile once the process exits.
        $collected = [System.Collections.Generic.List[string]]::new()
        $prompt | & $exe @cpArgs 2>&1 | ForEach-Object {
            $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
            Write-Output $line
            $collected.Add($line)
        }
        $exit = $LASTEXITCODE
        $text = $collected -join "`n"
        Set-Content -Path $OutputFile -Value $text -Encoding utf8
    } else {
        if ($CodexHome) { $env:CODEX_HOME = $CodexHome }
        $codexArgs = @("exec", "-C", $WorkDir, "-o", $OutputFile, "--color", "never",
                       "-c", "model_reasoning_effort=$CodexReasoning", "--skip-git-repo-check")
        if ($ExpertSession) {
            $codexArgs = @("exec", "-C", $WorkDir, "-o", $OutputFile, "--color", "never",
                           "-c", "model_reasoning_effort=medium", "--skip-git-repo-check")
            if ($ExpertModel) { $codexArgs += @("--model", $ExpertModel) }
            $codexArgs += "--dangerously-bypass-approvals-and-sandbox"
        } elseif ($Mode -eq "edit") {
            # `codex exec` is non-interactive (no approval prompts); --full-auto is not an exec flag.
            $codexArgs += @("--sandbox", "workspace-write")
            foreach ($d in $ExtraWritableDirs) { if ($d) { $codexArgs += @("--add-dir", $d) } }
            # A project tool that writes outside the worktree (a user-data folder, a cache) is
            # denied by the sandbox and fails for the wrong reason unless its folder is granted.
            foreach ($d in $sandboxWritableList) {
                if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
                $codexArgs += @("--add-dir", $d)
            }
            foreach ($d in $extraDirList) { $codexArgs += @("--add-dir", $d) }
        } else {
            $codexArgs += @("--sandbox", "read-only")
        }
        $codexArgs += "-"
        $log = $prompt | & $exe @codexArgs 2>&1
        $exit = $LASTEXITCODE
        $logText = ($log | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ } }) -join "`n"
        Set-Content -Path "$OutputFile.log" -Value $logText -Encoding utf8
        if (-not (Test-Path $OutputFile)) { Set-Content -Path $OutputFile -Value "" -Encoding utf8 }
    }
} finally {
    Pop-Location
}
# Claude prints its limit message to the output file; codex prints its to the run log. Only
# classify a non-zero run: a successful review that happens to discuss rate limits in its verdict
# must never be mistaken for the provider itself being out of allowance.
if ($exit -ne 0) {
    $seen = ""
    if (Test-Path $OutputFile) { $seen += [string](Get-Content -Raw -Path $OutputFile -Encoding utf8 -ErrorAction SilentlyContinue) }
    if (Test-Path "$OutputFile.log") { $seen += "`n" + [string](Get-Content -Raw -Path "$OutputFile.log" -Encoding utf8 -ErrorAction SilentlyContinue) }
    # The codex log begins with a verbatim echo of the prompt. Any line of it that also appears in
    # the prompt is the task talking, not the provider, so it is dropped before classification:
    # only lines the CLI itself produced may decide "out of quota" and when it comes back.
    $promptLines = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($pl in ($prompt -split "`r?`n")) { [void]$promptLines.Add($pl.Trim()) }
    $seen = (($seen -split "`r?`n") | Where-Object { -not $promptLines.Contains($_.Trim()) }) -join "`n"
    $quota = Get-QuotaBlock $seen
    if ($quota) {
        # 77 means "the provider refused on billing/quota grounds", which the supervisor treats as
        # "come back later", never as a defect in the work.
        if ($quota.Until) { Set-Content -Path "$OutputFile.cooldown" -Value $quota.Until.ToString("o") -Encoding ascii }
        Set-Content -Path "$OutputFile.quota" -Value $quota.Message -Encoding utf8
        Set-Content -Path "$OutputFile.exit" -Value "77"
        exit 77
    }
}
Set-Content -Path "$OutputFile.exit" -Value "$exit"
exit $exit
