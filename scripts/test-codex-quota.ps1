<#
.SYNOPSIS
Self-test for Get-CodexQuota in scripts/agent-supervisor.ps1.

.DESCRIPTION
Extracts Get-CodexQuota via the PowerShell AST and defines it in this script's own scope,
the same technique scripts/test-supervisor.ps1 uses -- the bottom of agent-supervisor.ps1
requires the GitHub CLI and enters an infinite poll loop, so dot-sourcing the whole file
is never an option.

Prints one PASS/FAIL line per check, then a summary line, and exits non-zero if any check
failed.
#>
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

try {
    . ([scriptblock]::Create((Get-FunctionSource $supervisorPath "Get-CodexAccountIdentity")))
} catch {
    Write-Host "FAIL Function extraction: Get-CodexAccountIdentity (scripts/agent-supervisor.ps1) -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

try {
    . ([scriptblock]::Create((Get-FunctionSource $supervisorPath "Get-CodexQuota")))
} catch {
    Write-Host "FAIL Function extraction: Get-CodexQuota (scripts/agent-supervisor.ps1) -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Get-CodexQuota: fixture
try {
    $fixturePath = Join-Path $PSScriptRoot "test-fixtures\codex-token-count-sample.jsonl"
    $tempSessionsRoot = Join-Path $env:TEMP "test-codex-quota-sessions-$([Guid]::NewGuid().ToString('N'))"
    $nestedDir = Join-Path $tempSessionsRoot "2026\09\15"
    New-Item -ItemType Directory -Force -Path $nestedDir -ErrorAction Stop | Out-Null
    try {
        Copy-Item -Path $fixturePath -Destination (Join-Path $nestedDir "rollout-sample.jsonl") -ErrorAction Stop

        $result = Get-CodexQuota $tempSessionsRoot
        Test-Result "Get-CodexQuota: reads plan_type from the latest matching token_count event" ($result.plan -eq "plus")
        Test-Result "Get-CodexQuota: returns exactly 2 quota entries" (@($result.quotas).Count -eq 2)

        $primary = @($result.quotas) | Where-Object { $_.label -eq "5 h" } | Select-Object -First 1
        $primaryResetOk = $false
        if ($primary) { try { [void][datetime]::Parse($primary.resetsAt); $primaryResetOk = $true } catch { } }
        Test-Result "Get-CodexQuota: '5 h' entry has usedPercent 85.0 and a parseable resetsAt" (
            $primary -and $primary.usedPercent -eq 85.0 -and $primaryResetOk
        )

        $secondary = @($result.quotas) | Where-Object { $_.label -eq "7 d" } | Select-Object -First 1
        Test-Result "Get-CodexQuota: '7 d' entry has usedPercent 99.0" (
            $secondary -and $secondary.usedPercent -eq 99.0
        )
    } finally {
        Remove-Item -Recurse -Force $tempSessionsRoot -ErrorAction SilentlyContinue
    }
} catch {
    Write-Host "FAIL Get-CodexQuota fixture checks -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Get-CodexQuota: missing directory
try {
    $missingRoot = Join-Path $env:TEMP "test-codex-quota-missing-$([Guid]::NewGuid().ToString('N'))"
    $result = Get-CodexQuota $missingRoot
    Test-Result "Get-CodexQuota: a nonexistent SessionsRoot yields plan = null with no exception" ($null -eq $result.plan)
    Test-Result "Get-CodexQuota: a nonexistent SessionsRoot yields zero quotas" (@($result.quotas).Count -eq 0)
} catch {
    Write-Host "FAIL Get-CodexQuota missing-directory check -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ------------------------------------------------- Get-CodexAccountIdentity: fingerprint and plan
# The point of the fingerprint is telling two CODEX_HOMEs of ONE account apart from two real
# accounts, so the checks are: same account id in two homes -> same fingerprint; a different
# account id -> a different one; and the raw id never appears in the output.
try {
    $idRoot = Join-Path $env:TEMP "test-codex-identity-$([Guid]::NewGuid().ToString('N'))"
    function New-FakeCodexHome([string]$Dir, [string]$AccountId, [string]$Plan) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $claims = @{ "https://api.openai.com/auth" = @{ chatgpt_account_id = $AccountId; chatgpt_plan_type = $Plan; chatgpt_subscription_last_checked = "2026-09-19T00:18:13Z" } }
        $json = $claims | ConvertTo-Json -Depth 8 -Compress
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $token = "header.$b64.signature"
        $auth = @{ auth_mode = "chatgpt"; tokens = @{ id_token = $token; account_id = $AccountId } } | ConvertTo-Json -Depth 8
        Set-Content -Path (Join-Path $Dir "auth.json") -Value $auth -Encoding utf8
    }
    New-FakeCodexHome (Join-Path $idRoot "primary") "acct-one" "plus"
    New-FakeCodexHome (Join-Path $idRoot "same") "acct-one" "plus"
    New-FakeCodexHome (Join-Path $idRoot "other") "acct-two" "prolite"

    $a = Get-CodexAccountIdentity (Join-Path $idRoot "primary")
    $b = Get-CodexAccountIdentity (Join-Path $idRoot "same")
    $c = Get-CodexAccountIdentity (Join-Path $idRoot "other")
    Test-Result "Get-CodexAccountIdentity: reads the plan from the id_token claim" ($a.plan -eq "plus") "got '$($a.plan)'"
    Test-Result "Get-CodexAccountIdentity: two homes of one account share a fingerprint" ($a.accountId -eq $b.accountId) "got '$($a.accountId)' vs '$($b.accountId)'"
    Test-Result "Get-CodexAccountIdentity: a different account gets a different fingerprint" ($a.accountId -ne $c.accountId -and $c.plan -eq "prolite")
    Test-Result "Get-CodexAccountIdentity: the fingerprint is 8 hex chars, not the raw id" ($a.accountId -match '^[0-9A-F]{8}$' -and $a.accountId -notmatch 'acct')

    $missingHome = Join-Path $idRoot "no-such-home"
    $m = Get-CodexAccountIdentity $missingHome
    Test-Result "Get-CodexAccountIdentity: a home with no auth.json yields nulls, no exception" ($null -eq $m.accountId -and $null -eq $m.plan)

    $brokenHome = Join-Path $idRoot "broken"
    New-Item -ItemType Directory -Path $brokenHome -Force | Out-Null
    Set-Content -Path (Join-Path $brokenHome "auth.json") -Value "{ not json" -Encoding utf8
    $bad = Get-CodexAccountIdentity $brokenHome
    Test-Result "Get-CodexAccountIdentity: a malformed auth.json yields nulls, no exception" ($null -eq $bad.accountId -and $null -eq $bad.plan)

    Remove-Item -Recurse -Force $idRoot -ErrorAction SilentlyContinue
} catch {
    Write-Host "FAIL Get-CodexAccountIdentity checks -- unexpected error: $($_.Exception.Message)"
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
