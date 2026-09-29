<#
.SYNOPSIS
Self-test for ConvertFrom-CopilotUserResponse and Get-CopilotQuota in scripts/agent-supervisor.ps1.

.DESCRIPTION
Follows the same AST-extraction pattern as scripts/test-supervisor.ps1: each function's source
is located with the PowerShell AST and defined in this script's own scope from its extent text,
without dot-sourcing the whole file (whose tail requires the GitHub CLI and enters a poll loop).

Prints one PASS/FAIL line per check, then a summary line, and exits non-zero if any check failed.
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
$fixturePath = Join-Path $PSScriptRoot "test-fixtures\copilot-user-sample.json"

# Get-CopilotQuota calls Invoke-GhJson/Invoke-Gh/Write-Utf8File on the (untested here) live-fetch
# path only; the cache-hit path exercised below never reaches them, so they are deliberately not
# extracted. Not extracting them keeps a real `gh` call out of this test entirely.
foreach ($fn in @("ConvertFrom-CopilotUserResponse", "Get-CopilotQuota")) {
    try {
        . ([scriptblock]::Create((Get-FunctionSource $supervisorPath $fn)))
    } catch {
        Write-Host "FAIL Function extraction: $fn (scripts/agent-supervisor.ps1) -- unexpected error: $($_.Exception.Message)"
        $script:failCount++
    }
}

# ----------------------------------------------------------------------------- ConvertFrom-CopilotUserResponse: fixture
try {
    if (-not (Test-Path $fixturePath)) { throw "fixture not found: $fixturePath" }
    $fixture = Get-Content -Raw -Path $fixturePath -Encoding utf8 | ConvertFrom-Json
    $result = ConvertFrom-CopilotUserResponse $fixture

    Test-Result "ConvertFrom-CopilotUserResponse: reads copilot_plan from the fixture" ($result.plan -eq "individual")

    $chat = @($result.quotas) | Where-Object { $_.label -match "(?i)^chat$" } | Select-Object -First 1
    Test-Result "ConvertFrom-CopilotUserResponse: quotas contains a chat-labelled entry with total 200 and remaining 149" (
        $chat -and $chat.total -eq 200 -and $chat.remaining -eq 149 -and $chat.usedPercent -eq 25.5
    )

    $premium = @($result.quotas) | Where-Object { $_.label -match "(?i)premium" } | Select-Object -First 1
    Test-Result "ConvertFrom-CopilotUserResponse: quotas does not contain a premium_interactions entry (entitlement is 0)" ($null -eq $premium)

    Test-Result "ConvertFrom-CopilotUserResponse: noPremiumRequests is true when premium_interactions entitlement is 0" ($result.noPremiumRequests -eq $true)

    Test-Result "ConvertFrom-CopilotUserResponse: resetsAt on the chat entry is a parseable ISO-8601 date" (
        $chat -and $chat.resetsAt -and ([datetime]::Parse([string]$chat.resetsAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)).Year -eq 2026
    )
} catch {
    Write-Host "FAIL ConvertFrom-CopilotUserResponse: fixture -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- ConvertFrom-CopilotUserResponse: empty/malformed
try {
    $emptyResult = ConvertFrom-CopilotUserResponse ([pscustomobject]@{})
    Test-Result "ConvertFrom-CopilotUserResponse: an empty object yields plan null and no quotas, without throwing" (
        $null -eq $emptyResult.plan -and @($emptyResult.quotas).Count -eq 0
    )

    $nullResult = ConvertFrom-CopilotUserResponse $null
    Test-Result "ConvertFrom-CopilotUserResponse: `$null input yields plan null and no quotas, without throwing" (
        $null -eq $nullResult.plan -and @($nullResult.quotas).Count -eq 0
    )

    $malformedResult = ConvertFrom-CopilotUserResponse ([pscustomobject]@{ copilot_plan = "individual"; quota_snapshots = "not an object" })
    Test-Result "ConvertFrom-CopilotUserResponse: a malformed quota_snapshots value does not throw" (
        $malformedResult.plan -eq "individual" -and @($malformedResult.quotas).Count -eq 0
    )
} catch {
    Write-Host "FAIL ConvertFrom-CopilotUserResponse: empty/malformed -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Get-CopilotQuota: caching
# Deliberately at top-level scope (not inside a function/scriptblock), the same way
# scripts/test-supervisor.ps1 sets $statePath for Load-State/Save-State: Get-CopilotQuota, as
# extracted from agent-supervisor.ps1, reads the bare $statePath variable via its own lexical
# (definition-site) scope chain, which is this script's top-level scope.
try {
    $tempStateDir = Join-Path $env:TEMP "test-copilot-quota-state-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $tempStateDir -ErrorAction Stop | Out-Null
    try {
        $statePath = $tempStateDir
        $cachePath = Join-Path $tempStateDir "copilot-quota-cache.json"

        # A plan name and quota values that could not have come from converting the fixture
        # above (fixture is "individual" / chat 149-of-200 / noPremiumRequests true): if
        # Get-CopilotQuota ignored the cache and re-derived from the fixture (or called `gh`,
        # which is not installed as a mock here), these exact values would not come back.
        $seeded = [pscustomobject]@{
            fetchedAt         = (Get-Date).AddSeconds(-10).ToString("o")
            plan              = "test-seeded-plan"
            quotas            = @(@{ label = "Bogus"; usedPercent = 42; remaining = 3; total = 4; resetsAt = "2099-01-01T00:00:00.0000000"; source = "test-cache" })
            noPremiumRequests = $false
        }
        [System.IO.File]::WriteAllText($cachePath, ($seeded | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

        $cachedQuota = Get-CopilotQuota
        Test-Result "Get-CopilotQuota: a fresh (10s-old) cache is returned unchanged, with no `gh` call" (
            $cachedQuota.plan -eq "test-seeded-plan" -and
            @($cachedQuota.quotas).Count -eq 1 -and
            (@($cachedQuota.quotas)[0].label -eq "Bogus") -and
            $cachedQuota.noPremiumRequests -eq $false
        )
    } finally {
        Remove-Item -Recurse -Force $tempStateDir -ErrorAction SilentlyContinue
    }
} catch {
    Write-Host "FAIL Get-CopilotQuota: caching -- unexpected error: $($_.Exception.Message)"
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
