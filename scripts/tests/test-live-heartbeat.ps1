<#
.SYNOPSIS
Self-test for the live.json heartbeat added to Invoke-Agent in scripts/agent-supervisor.ps1.

.DESCRIPTION
Exercises Invoke-Agent's sliced WaitForExit loop and the new Write-Live helper as black boxes,
without touching GitHub or launching any real provider CLI, and without dot-sourcing
agent-supervisor.ps1 directly (its module-level code requires the GitHub CLI, checks a lock
file, and enters an infinite poll loop). Instead, exactly like scripts/test-supervisor.ps1, each
function's source is located with the PowerShell AST and defined from its extent text -- here,
in two places: this script's own top-level scope (for a synchronous check of the Write-Live
failure path), and a background runspace's scope (so Invoke-Agent can run for real, against a
real dummy child process, while this script polls .agent-state/live.json and the worker file
concurrently -- something dot-sourcing or a purely synchronous call could not observe).

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

# ----------------------------------------------------------------------------- AST extraction
# Parses the file's text without executing it, locates the named FunctionDefinitionAst, and
# returns its exact source text. Dot-sourcing that text as a scriptblock defines only that
# function -- nothing else in agent-supervisor.ps1 (module-level startup/lock/poll-loop code)
# ever runs.
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

$FunctionNames = @("Write-Utf8File", "Get-ProcessTreeIds", "Confirm-ProcessTerminated", "Write-Live", "Invoke-Agent")
$script:funcSource = @{}
foreach ($fn in $FunctionNames) {
    try {
        $script:funcSource[$fn] = Get-FunctionSource $supervisorPath $fn
    } catch {
        Write-Host "FAIL Function extraction: $fn (scripts/agent-supervisor.ps1) -- unexpected error: $($_.Exception.Message)"
        $script:failCount++
    }
}

# Stubs for the two pieces of Invoke-Agent's account-selection logic this test does not exercise
# (multi-login cooldown bookkeeping is covered by scripts/test-supervisor.ps1's own helpers) --
# always the bare provider name, no codexHome, so Invoke-Agent's argument list for the dummy
# child stays exactly what this test's dummy-worker.ps1 expects.
function Get-ProviderAccounts([string]$Provider) { return @([pscustomobject]@{ key = $Provider; label = "primary"; codexHome = $null }) }
function Get-ReadyAccount([string]$Provider) { return (Get-ProviderAccounts $Provider)[0] }
# Host-wide cleanup is not part of this dummy-worker test. Never inspect/kill real agents.
function Stop-OrphanedProcesses([string]$Tag) { }
function Stop-LeakedLogHolders([string]$Tag) { }

# Define everything in THIS script's top-level scope too (same rationale as test-supervisor.ps1:
# Invoke-Agent/Write-Live read $statePath/$runner/$CopilotModel via lexical scope chain, so the
# test code that sets those variables must run at the same top-level scope for the linkage to
# work). Used below by the synchronous Write-Live-failure checks and the direct role/step checks.
$script:logLines = New-Object System.Collections.Generic.List[string]
function Write-Log([string]$Message) { $script:logLines.Add($Message) }
foreach ($fn in $FunctionNames) {
    if ($script:funcSource.ContainsKey($fn)) {
        try {
            . ([scriptblock]::Create($script:funcSource[$fn]))
        } catch {
            Write-Host "FAIL Function definition: $fn -- unexpected error: $($_.Exception.Message)"
            $script:failCount++
        }
    }
}

$testRoot = Join-Path $env:TEMP "test-live-heartbeat-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null

function New-TempState {
    $p = Join-Path $testRoot "state-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    return $p
}

# A stand-in for run-agent.ps1: accepts the same named parameters Invoke-Agent's $argList can
# pass, sleeps for the number of seconds written into the prompt file (Invoke-Agent writes
# -Prompt verbatim to $promptFile before launching), then writes the output file and its
# ".exit" sidecar the same way run-agent.ps1 does, so Invoke-Agent's own exit-code/output
# reading logic runs unmodified.
$dummyWorkerPath = Join-Path $testRoot "dummy-worker.ps1"
@'
param(
    [string]$Provider, [string]$Mode, [string]$PromptFile, [string]$WorkDir, [string]$OutputFile,
    [string[]]$ExtraWritableDirs, [string]$CodexReasoning, [string]$CodexHome, [string]$CopilotModel,
    [switch]$ExpertSession
)
$seconds = 1
try { $seconds = [int]((Get-Content -Raw -Path $PromptFile).Trim()) } catch { }
Start-Sleep -Seconds $seconds
Set-Content -Path $OutputFile -Value "dummy output" -Encoding utf8
if ($ExpertSession) { Add-Content -Path $OutputFile -Value 'expert option received' }
Set-Content -Path "$OutputFile.exit" -Value "0" -Encoding ascii
exit 0
'@ | Set-Content -Path $dummyWorkerPath -Encoding utf8

# ----------------------------------------------------------------------------- direct Write-Live checks
# Covers all four $Tag shapes named in the task (only two of which get exercised end-to-end via
# Invoke-Agent below) without paying for a process launch.
try {
    $liveStatePath = New-TempState
    $statePath = $liveStatePath
    $livePath = Join-Path $statePath "live.json"

    function Test-LiveJson([string]$Tag, [datetime]$StartedAtUtc, [string]$Deadline, [string]$ExpectRole, [string]$ExpectStep, $ExpectIssue) {
        Write-Live -Tag $Tag -Provider "claude" -StartedAtUtc $StartedAtUtc -Deadline $Deadline
        $bytes = (Get-Item $livePath).Length
        $raw = Get-Content -Raw -Path $livePath -Encoding utf8
        $obj = $null
        try { $obj = $raw | ConvertFrom-Json } catch { }
        $requiredFields = @("updatedAt", "step", "issue", "role", "provider", "tag", "startedAt", "elapsedSeconds", "deadline", "lastAction")
        $hasAllFields = $true
        foreach ($f in $requiredFields) { if (-not ($obj.PSObject.Properties.Name -contains $f)) { $hasAllFields = $false } }
        Test-Result "Write-Live ($Tag): writes valid JSON <= 4096 bytes with all required fields" ($obj -and $bytes -le 4096 -and $hasAllFields) "bytes=$bytes"
        Test-Result "Write-Live ($Tag): role=$ExpectRole, step=$ExpectStep" ($obj.role -eq $ExpectRole -and $obj.step -eq $ExpectStep)
        Test-Result "Write-Live ($Tag): issue=$ExpectIssue" ($obj.issue -eq $ExpectIssue)
        Test-Result "Write-Live ($Tag): lastAction is the safe placeholder" ($null -eq $obj.lastAction.at -and $obj.lastAction.kind -eq "unknown" -and $obj.lastAction.summary -eq "")
        Test-Result "Write-Live ($Tag): provider and tag are carried through" ($obj.provider -eq "claude" -and $obj.tag -eq $Tag)
    }

    $now = (Get-Date).ToUniversalTime()
    $deadlineIso = $now.AddMinutes(30).ToString("o")
    Test-LiveJson "objective-15-plan" $now $deadlineIso "planner" "planner" $null
    Test-LiveJson "issue-8-review-2" $now.AddSeconds(-5) $deadlineIso "reviewer" "reviewer" 8
    Test-LiveJson "issue-42-implement" $now.AddSeconds(-5) $deadlineIso "author" "author" 42
    Test-LiveJson "issue-99-revise-3" $now.AddSeconds(-5) $deadlineIso "reviser" "revision" 99
} catch {
    Write-Host "FAIL Direct Write-Live checks -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Write-Live failure is caught, not thrown
try {
    $failStatePath = New-TempState
    $statePath = $failStatePath
    $runner = $dummyWorkerPath
    $CopilotModel = $null
    $script:logLines.Clear()

    # An unwritable "path": pre-create a directory named live.json, so Write-Utf8File's
    # File.WriteAllText throws (the target already exists as a directory) every time Write-Live
    # runs inside Invoke-Agent's loop.
    New-Item -ItemType Directory -Force -Path (Join-Path $statePath "live.json") | Out-Null

    $tag = "issue-7-implement"
    $threw = $false
    $result = $null
    try {
        $result = Invoke-Agent -Provider "claude" -Mode "edit" -Prompt "3" -WorkDir $testRoot -Tag $tag -TimeoutMinutes 1
    } catch {
        $threw = $true
    }

    Test-Result "Invoke-Agent: a Write-Live failure does not throw" (-not $threw)
    Test-Result "Invoke-Agent: a Write-Live failure does not change Ok/TimedOut/Exit" ($result -and $result.Ok -eq $true -and $result.TimedOut -eq $false -and $result.Exit -eq 0)
    Test-Result "Invoke-Agent: a Write-Live failure is logged" (@($script:logLines | Where-Object { $_ -match "Write-Live failed" }).Count -gt 0)
    Test-Result "Invoke-Agent: worker.json is still cleaned up after a Write-Live failure" (-not (Test-Path (Join-Path $statePath "$tag.worker.json")))
    Test-Result "Invoke-Agent: live.json path was left as the pre-existing directory (Write-Live really did fail, not silently succeed elsewhere)" (Test-Path (Join-Path $statePath "live.json") -PathType Container)
} catch {
    Write-Host "FAIL Write-Live failure checks -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- background runspace driver
# Runs Invoke-Agent on a separate thread against a real dummy child process, so this script's
# main thread can poll .agent-state/live.json and the worker file WHILE the child is still
# running -- not just inspect the final state after Invoke-Agent returns. The background
# runspace gets its own copy of the same AST-extracted function source (never a shared
# dot-sourced module), consistent with how this whole file avoids dot-sourcing
# agent-supervisor.ps1 itself.
$backgroundScript = @"
`$ErrorActionPreference = "Continue"
function Write-Log([string]`$Message) { }
function Get-ProviderAccounts([string]`$Provider) { return @([pscustomobject]@{ key = `$Provider; label = "primary"; codexHome = `$null }) }
function Get-ReadyAccount([string]`$Provider) { return (Get-ProviderAccounts `$Provider)[0] }
function Stop-OrphanedProcesses([string]`$Tag) { }
function Stop-LeakedLogHolders([string]`$Tag) { }
$($script:funcSource["Write-Utf8File"])
$($script:funcSource["Get-ProcessTreeIds"])
$($script:funcSource["Confirm-ProcessTerminated"])
$($script:funcSource["Write-Live"])
$($script:funcSource["Invoke-Agent"])
Invoke-Agent -Provider `$Provider -Mode `$Mode -Prompt `$Prompt -WorkDir `$WorkDir -Tag `$Tag -TimeoutMinutes `$TimeoutMinutes
"@

function Start-InvokeAgentAsync([string]$StatePath, [string]$Runner, [string]$Provider, [string]$Mode, [string]$Prompt, [string]$WorkDir, [string]$Tag, [int]$TimeoutMinutes) {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable("statePath", $StatePath)
    $rs.SessionStateProxy.SetVariable("runner", $Runner)
    $rs.SessionStateProxy.SetVariable("CopilotModel", $null)
    $rs.SessionStateProxy.SetVariable("Provider", $Provider)
    $rs.SessionStateProxy.SetVariable("Mode", $Mode)
    $rs.SessionStateProxy.SetVariable("Prompt", $Prompt)
    $rs.SessionStateProxy.SetVariable("WorkDir", $WorkDir)
    $rs.SessionStateProxy.SetVariable("Tag", $Tag)
    $rs.SessionStateProxy.SetVariable("TimeoutMinutes", $TimeoutMinutes)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:backgroundScript)
    $async = $ps.BeginInvoke()
    return [pscustomobject]@{ PS = $ps; Runspace = $rs; Async = $async }
}

# Polls live.json and the worker file every 500ms while the background call is still running,
# up to $MaxWaitSeconds. Returns @{ SawValidLiveWhileRunning; SawConfirmedWorkerWhileRunning }.
function Watch-RunningState([string]$StatePath, [string]$Tag, [object]$Handle, [int]$MaxWaitSeconds) {
    $livePath = Join-Path $StatePath "live.json"
    $workerPath = Join-Path $StatePath "$Tag.worker.json"
    $sawLive = $false
    $sawWorker = $false
    $deadline = (Get-Date).AddSeconds($MaxWaitSeconds)
    while (-not $Handle.Async.IsCompleted -and (Get-Date) -lt $deadline) {
        if (-not $sawLive -and (Test-Path $livePath)) {
            try {
                $raw = Get-Content -Raw -Path $livePath -Encoding utf8
                $bytes = (Get-Item $livePath).Length
                $obj = $raw | ConvertFrom-Json
                if ($obj -and $bytes -le 4096 -and $obj.tag -eq $Tag -and $obj.updatedAt -and $obj.PSObject.Properties.Name -contains "lastAction" -and $obj.lastAction.kind -eq "unknown") {
                    $sawLive = $true
                }
            } catch { }
        }
        if (-not $sawWorker -and (Test-Path $workerPath)) {
            try {
                $w = Get-Content -Raw -Path $workerPath -Encoding utf8 | ConvertFrom-Json
                if ([int64]$w.pid -gt 0 -and $w.tag -eq $Tag) { $sawWorker = $true }
            } catch { }
        }
        if ($sawLive -and $sawWorker) { break }
        Start-Sleep -Milliseconds 500
    }
    return @{ SawValidLiveWhileRunning = $sawLive; SawConfirmedWorkerWhileRunning = $sawWorker }
}

# ----------------------------------------------------------------------------- short-lived dummy child (finishes well inside the timeout)
try {
    $shortStatePath = New-TempState
    $tag = "issue-42-implement"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $handle = Start-InvokeAgentAsync $shortStatePath $dummyWorkerPath "claude" "edit" "25" $testRoot $tag 1
    $watch = Watch-RunningState $shortStatePath $tag $handle 40

    # EndInvoke blocks until the background pipeline actually finishes -- no separate wait needed.
    $result = $null
    $err = $null
    try { $result = $handle.PS.EndInvoke($handle.Async) | Select-Object -Last 1 } catch { $err = $_ }
    $stopwatch.Stop()
    $handle.PS.Dispose()
    $handle.Runspace.Close()

    Test-Result "Invoke-Agent (short-lived child): live.json was written, valid, <= 4096 bytes, while the child was still running" $watch.SawValidLiveWhileRunning
    Test-Result "Invoke-Agent (short-lived child): worker.json had a confirmed (pid>0) record while the child was still running" $watch.SawConfirmedWorkerWhileRunning
    Test-Result "Invoke-Agent (short-lived child): returned without throwing" ($null -eq $err) "$err"
    Test-Result "Invoke-Agent (short-lived child): Ok=true, TimedOut=false, Exit=0" ($result -and $result.Ok -eq $true -and $result.TimedOut -eq $false -and $result.Exit -eq 0)
    Test-Result "Invoke-Agent (short-lived child): worker.json cleaned up after a successful finish" (-not (Test-Path (Join-Path $shortStatePath "$tag.worker.json")))
    Test-Result "Invoke-Agent (short-lived child): finished in well under the 1-minute timeout budget" ($stopwatch.Elapsed.TotalSeconds -lt 50) "elapsed=$($stopwatch.Elapsed.TotalSeconds)s"
} catch {
    Write-Host "FAIL Short-lived dummy child checks -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- long-lived dummy child (outlives the timeout)
try {
    $longStatePath = New-TempState
    $tag = "issue-99-revise-3"
    $timeoutMinutes = 1
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $handle = Start-InvokeAgentAsync $longStatePath $dummyWorkerPath "claude" "edit" "300" $testRoot $tag $timeoutMinutes
    $watch = Watch-RunningState $longStatePath $tag $handle 50

    # EndInvoke blocks until the background pipeline actually finishes -- no separate wait needed.
    $result = $null
    $err = $null
    try { $result = $handle.PS.EndInvoke($handle.Async) | Select-Object -Last 1 } catch { $err = $_ }
    $stopwatch.Stop()
    $handle.PS.Dispose()
    $handle.Runspace.Close()

    $budgetSeconds = $timeoutMinutes * 60
    Test-Result "Invoke-Agent (long-lived child): live.json was written, valid, <= 4096 bytes, while the child was still running" $watch.SawValidLiveWhileRunning
    Test-Result "Invoke-Agent (long-lived child): worker.json had a confirmed (pid>0) record while the child was still running" $watch.SawConfirmedWorkerWhileRunning
    Test-Result "Invoke-Agent (long-lived child): returned without throwing" ($null -eq $err) "$err"
    Test-Result "Invoke-Agent (long-lived child): TimedOut=true, Ok=false" ($result -and $result.TimedOut -eq $true -and $result.Ok -eq $false)
    Test-Result "Invoke-Agent (long-lived child): worker.json cleaned up after the timeout kill" (-not (Test-Path (Join-Path $longStatePath "$tag.worker.json")))
    # Same total budget as today's single WaitForExit call: the slicing must not shrink or
    # stretch the point at which a kill triggers, within a few seconds either way.
    Test-Result "Invoke-Agent (long-lived child): total elapsed time preserves the timeout budget (within a few seconds)" ($stopwatch.Elapsed.TotalSeconds -ge ($budgetSeconds - 3) -and $stopwatch.Elapsed.TotalSeconds -le ($budgetSeconds + 15)) "elapsed=$($stopwatch.Elapsed.TotalSeconds)s, budget=${budgetSeconds}s"
} catch {
    Write-Host "FAIL Long-lived dummy child checks -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# Reusing a phase tag must preserve both invocations' evidence, while worker ownership
# still uses the logical tag. Exercise the real launcher, not a filename-only assertion.
try {
    $statePath = New-TempState
    $runner = $dummyWorkerPath
    $tag = 'issue-7-revise-1'
    $first = Invoke-Agent -Provider 'claude' -Mode 'edit' -Prompt '1' -WorkDir $testRoot -Tag $tag -TimeoutMinutes 1
    $firstOutput = @(Get-ChildItem -LiteralPath $statePath -Filter '*.output.md')[0]
    $firstText = Get-Content -LiteralPath $firstOutput.FullName -Raw
    $second = Invoke-Agent -Provider 'claude' -Mode 'edit' -Prompt '1' -WorkDir $testRoot -Tag $tag -TimeoutMinutes 1 -ExpertSession
    $outputs = @(Get-ChildItem -LiteralPath $statePath -Filter '*.output.md')
    Test-Result 'Repeated tag: both real dummy workers finish successfully' ($first.Ok -and $second.Ok)
    Test-Result 'Repeated tag: two distinct outputs survive' ($outputs.Count -eq 2 -and (Get-Content -LiteralPath $firstOutput.FullName -Raw) -eq $firstText)
    Test-Result 'Expert option reaches the child runner' (@($outputs | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'expert option received' }).Count -eq 1)
    Test-Result 'Repeated tag: logical worker record is cleaned up' (-not (Test-Path (Join-Path $statePath "$tag.worker.json")))
} catch {
    Test-Result 'Repeated tag: real launcher completes without error' $false $_.Exception.Message
}

$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
$allowedTestPrefix = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\test-live-heartbeat-'
if (-not $resolvedTestRoot.StartsWith($allowedTestPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path' }
Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue

# ----------------------------------------------------------------------------- summary
Write-Host ""
if ($script:failCount -gt 0) {
    Write-Host "SUMMARY: $script:failCount check(s) FAILED"
    exit 1
} else {
    Write-Host "SUMMARY: all checks passed"
    exit 0
}
