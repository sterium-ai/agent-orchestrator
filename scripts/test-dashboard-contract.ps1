<#
.SYNOPSIS
Contract test for the owner dashboard: runs a real ``agent-supervisor.ps1 -DryRun -Once``
cycle and asserts the shape and safety of the ``dashboard.json`` it writes.

.DESCRIPTION
Write-Dashboard no longer skips itself in -DryRun mode (see docs/AGENT_SUPERVISOR.md and issue
#67), so a single -DryRun -Once invocation is now enough to observe its real output without
touching GitHub state or the working repo. This script launches exactly that invocation with
its working directory redirected to a throwaway %TEMP% root (the same isolation trick
scripts/test-supervisor.ps1 uses for its own -DryRun smoke check: agent-supervisor.ps1 resolves
docs\agent-prompts and its default .agent-state directory relative to the process's working
directory, not the script's location), then reads the dashboard.json that lands in that
isolated .agent-state and checks:

  - providers.claude / providers.codex / providers.copilot each carry a `plan` key (value may
    be $null) and a `quotas` key (an array, possibly empty)
  - providers.copilot also carries a `noPremiumRequests` key
  - usage.claude / usage.codex / usage.copilot no longer carry the retired sessionsLast4h /
    tokensLast4h keys
  - the raw file text contains none of accessToken, refreshToken, id_token, 'Bearer ' (case
    insensitive) -- nothing that could leak a credential into a file served over HTTP
  - the supervisor's own captured stdout/stderr for that run contains no PowerShell exception
    text (Exception / ParserError / "is not recognized")

Prints one PASS/FAIL line per assertion and a summary. Exits non-zero if any assertion failed.
Like test-supervisor.ps1's own -DryRun smoke check, this requires the GitHub CLI to be
installed and authenticated on the host (agent-supervisor.ps1 checks both at startup even in
-DryRun mode) and reports SKIP, never a false PASS, when that requirement is not met.
#>
[CmdletBinding()]
param()

# "Continue", not "Stop": native stderr from a child process (gh, or the supervisor itself)
# would otherwise become a terminating error under "Stop" in Windows PowerShell 5.1.
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

# Windows PowerShell 5.1's [System.Diagnostics.Process]::Kill() only ends the immediate
# process; taskkill /T walks and ends the whole tree a timed-out supervisor run may have
# spawned (e.g. a hung `gh` call).
function Stop-ProcessTree([int]$ProcessId) {
    & taskkill.exe /PID $ProcessId /T /F *> $null
}

# Built directly on System.Diagnostics.Process, with ReadToEndAsync started before
# WaitForExit, the same pattern agent-supervisor.ps1's own Invoke-AcceptanceCommands uses:
# Start-Process -PassThru has shown a null ExitCode after a timed WaitForExit on this host,
# and BeginOutputReadLine's DataReceived events (no subscriber) would silently discard the
# very output this test needs to inspect for exception text.
function Invoke-CapturedProcess([string]$FilePath, [string]$Arguments, [string]$WorkingDirectory, [int]$TimeoutMilliseconds) {
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
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if ($proc.WaitForExit($TimeoutMilliseconds)) {
            $proc.WaitForExit()   # flushes the async stream readers before ExitCode is read
            [System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), 5000) | Out-Null
            $stdOut = if ($outTask.IsCompleted) { [string]$outTask.Result } else { "" }
            $stdErr = if ($errTask.IsCompleted) { [string]$errTask.Result } else { "" }
            return @{ TimedOut = $false; ExitCode = $proc.ExitCode; StdOut = $stdOut; StdErr = $stdErr }
        } else {
            Stop-ProcessTree $proc.Id
            try { $proc.WaitForExit(5000) | Out-Null } catch { }
            $stdOut = ""; $stdErr = ""
            try { if ($outTask.IsCompleted) { $stdOut = [string]$outTask.Result } } catch { }
            try { if ($errTask.IsCompleted) { $stdErr = [string]$errTask.Result } } catch { }
            return @{ TimedOut = $true; ExitCode = $null; StdOut = $stdOut; StdErr = $stdErr }
        }
    } finally {
        $proc.Dispose()
    }
}

# ----------------------------------------------------------------------------- unit: array shape
# Windows PowerShell 5.1 unrolls a zero- or one-element array coming out of a function call when
# it is assigned directly ($x = Get-Foo): a single quota entry becomes a bare object, not a
# 1-element array, and an empty result becomes $null. Write-Dashboard guards every quotas
# assignment with @(...) for exactly this reason. This proves that idiom against fixture data
# for 0, 1 and 2-entry results -- not live host quota data, which might always happen to return
# 2+ entries and never exercise the collapsing case -- both that the PowerShell value stays a
# real array and that it still serializes as a JSON array (`[...]`, never `null` or a bare `{}`)
# after the same ConvertTo-Json step Write-Dashboard uses. Runs unconditionally, before the `gh`
# prerequisite check below, since it exercises a pure PowerShell/JSON behavior with no dependency
# on the GitHub CLI or a live supervisor run.
function Get-FixtureQuotaArray([int]$Count) {
    $result = @()
    for ($i = 0; $i -lt $Count; $i++) { $result += @{ label = "w$i"; usedPercent = $i } }
    return $result
}
foreach ($count in 0, 1, 2) {
    $label = "$count entr$(if ($count -eq 1) { 'y' } else { 'ies' })"
    $wrapped = @(Get-FixtureQuotaArray $count)
    Test-Result "quotas fixture ($label): @(...) wrapping preserves array type" ($wrapped -is [array]) "got type $($wrapped.GetType().Name)"
    $json = ([pscustomobject]@{ quotas = $wrapped }) | ConvertTo-Json -Depth 5 -Compress
    Test-Result "quotas fixture ($label): serializes as a JSON array" ($json -match '"quotas":\[') "json: $json"
}
# Same check for the Codex/Copilot shape: a reader that returns one object wrapping its own
# quotas array (rather than the array directly), the way Get-CodexQuota and Get-CopilotQuota do.
function Get-FixtureQuotaObject([int]$Count) {
    return [pscustomobject]@{ plan = "pro"; quotas = @(Get-FixtureQuotaArray $Count) }
}
foreach ($count in 0, 1, 2) {
    $label = "$count entr$(if ($count -eq 1) { 'y' } else { 'ies' })"
    $objResult = @(Get-FixtureQuotaObject $count)
    $objQuota = if ($objResult.Count -gt 0) { $objResult[0] } else { $null }
    $rewrapped = @($objQuota.quotas)
    Test-Result "quotas object fixture ($label): @(...) wrapping preserves array type" ($rewrapped -is [array]) "got type $($rewrapped.GetType().Name)"
    $json = ([pscustomobject]@{ quotas = $rewrapped }) | ConvertTo-Json -Depth 5 -Compress
    Test-Result "quotas object fixture ($label): serializes as a JSON array" ($json -match '"quotas":\[') "json: $json"
}

# ----------------------------------------------------------------------------- prerequisite: gh
$ghCommand = @(Get-Command "gh.exe", "gh.cmd", "gh" -ErrorAction SilentlyContinue) | Select-Object -First 1
if (-not $ghCommand) {
    Write-Host "SKIP Dashboard contract: the GitHub CLI is not installed / not on PATH (agent-supervisor.ps1 requires it even in -DryRun mode)"
    Write-Host ""
    Write-Host "SUMMARY: skipped (GitHub CLI unavailable)"
    exit 0
}
$authResult = Invoke-CapturedProcess $ghCommand.Source "auth status" $null 10000
if ($authResult.TimedOut) {
    Write-Host "SKIP Dashboard contract: 'gh auth status' did not respond within 10s"
    Write-Host ""
    Write-Host "SUMMARY: skipped (GitHub CLI did not respond)"
    exit 0
}
if ($authResult.ExitCode -ne 0) {
    Write-Host "SKIP Dashboard contract: the GitHub CLI is installed but not authenticated (agent-supervisor.ps1 requires 'gh auth login' even in -DryRun mode)"
    Write-Host ""
    Write-Host "SUMMARY: skipped (GitHub CLI unauthenticated)"
    exit 0
}

# ----------------------------------------------------------------------------- run the dry run
# Same isolation as test-supervisor.ps1's own -DryRun smoke check: a throwaway %TEMP% root
# containing only the docs\agent-prompts directory agent-supervisor.ps1 checks for at startup.
# Its default ".agent-state" (and therefore dashboard.json) lands inside that same root. The
# real repo and its real .agent-state/ are never touched.
$supervisorScript = Join-Path $PSScriptRoot "agent-supervisor.ps1"
$dryRunRoot = Join-Path $env:TEMP "test-dashboard-contract-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path (Join-Path $dryRunRoot "docs\agent-prompts") -ErrorAction Stop | Out-Null
try {
    # Any repository the authenticated account can read works; a dry run only lists issues.
    $dryRunRepo = if ($env:AGENT_TEST_REPOSITORY) { $env:AGENT_TEST_REPOSITORY } else { "octocat/Hello-World" }
    $dryRunArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Repository {1} -DryRun -Once' -f $supervisorScript, $dryRunRepo
    $result = Invoke-CapturedProcess "powershell.exe" $dryRunArgs $dryRunRoot 60000

    if ($result.TimedOut) {
        Test-Result "agent-supervisor.ps1 -DryRun -Once completes within 60s" $false "timed out and was killed"
    } else {
        Test-Result "agent-supervisor.ps1 -DryRun -Once exits 0" ($result.ExitCode -eq 0) "exit code $($result.ExitCode)"
    }

    $combinedOutput = [string]$result.StdOut + "`n" + [string]$result.StdErr
    $exceptionPatterns = @("Exception", "ParserError", "is not recognized")
    $hits = @($exceptionPatterns | Where-Object { $combinedOutput -match [regex]::Escape($_) })
    Test-Result "supervisor stdout/stderr contains no PowerShell exception text" ($hits.Count -eq 0) "found: $($hits -join ', ')"

    $dashboardPath = Join-Path $dryRunRoot ".agent-state\dashboard.json"
    if (-not (Test-Path $dashboardPath)) {
        Test-Result "dashboard.json was written" $false "$dashboardPath does not exist"
    } else {
        Test-Result "dashboard.json was written" $true

        $rawText = Get-Content -Raw -Path $dashboardPath -Encoding utf8
        $doc = $null
        try { $doc = $rawText | ConvertFrom-Json -ErrorAction Stop } catch { }
        Test-Result "dashboard.json parses as JSON" ($null -ne $doc)

        if ($doc) {
            foreach ($p in @("claude", "codex", "copilot")) {
                $prov = $doc.providers.$p
                $hasPlan = [bool]($prov -and ($prov.PSObject.Properties.Name -contains "plan"))
                Test-Result "providers.$p has a 'plan' key" $hasPlan

                # ConvertFrom-Json's own array/null collapsing in Windows PowerShell 5.1 makes
                # $prov.quotas unable to tell a JSON "[]" apart from a JSON "null" once parsed --
                # exactly the ambiguity this assertion needs to catch (a provider whose quotas
                # got serialized as null must FAIL, not slip through as "possibly empty"). This
                # instead greps the raw JSON text for that one provider's own "quotas" field
                # (bounded by its opening brace, with no other object in between: every field
                # before "quotas" in providerFields is a scalar) and checks the literal token
                # that follows the colon is an array-open, not the word null.
                $quotasMatch = [regex]::Match($rawText, ('"' + $p + '"\s*:\s*\{[^{}]*?"quotas"\s*:\s*(\[|null)'))
                $quotasShapeOk = $quotasMatch.Success -and ($quotasMatch.Groups[1].Value -eq "[")
                $quotasDetail = if (-not $quotasMatch.Success) { "'quotas' field not found for $p" } else { "raw token: $($quotasMatch.Groups[1].Value)" }
                Test-Result "providers.$p has a 'quotas' key that is an array (possibly empty)" $quotasShapeOk $quotasDetail
            }

            $copilotProv = $doc.providers.copilot
            $copilotHasFlag = [bool]($copilotProv -and ($copilotProv.PSObject.Properties.Name -contains "noPremiumRequests"))
            Test-Result "providers.copilot has a 'noPremiumRequests' key" $copilotHasFlag

            foreach ($p in @("claude", "codex", "copilot")) {
                $u = $doc.usage.$p
                $noStale = [bool]($u -and -not ($u.PSObject.Properties.Name -contains "sessionsLast4h") -and -not ($u.PSObject.Properties.Name -contains "tokensLast4h"))
                Test-Result "usage.$p has no sessionsLast4h/tokensLast4h keys" $noStale
            }
        }

        $lowerText = $rawText.ToLowerInvariant()
        foreach ($secret in @("accesstoken", "refreshtoken", "id_token", "bearer ")) {
            Test-Result "dashboard.json does not contain '$secret'" (-not $lowerText.Contains($secret))
        }
    }
} finally {
    Remove-Item -Recurse -Force $dryRunRoot -ErrorAction SilentlyContinue
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
