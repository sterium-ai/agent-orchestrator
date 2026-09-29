<#
.SYNOPSIS
Self-test for ConvertFrom-ClaudeUsageResponse and Get-ClaudeQuota in scripts/agent-supervisor.ps1.

.DESCRIPTION
Follows the same AST-extraction pattern as scripts/test-copilot-quota.ps1: each function's
source is located with the PowerShell AST and defined in this script's own scope from its
extent text, without dot-sourcing the whole file (whose tail requires the GitHub CLI and enters
a poll loop).

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
$fixturePath = Join-Path $PSScriptRoot "test-fixtures\claude-oauth-usage-sample.json"

# Write-Log is stubbed as a no-op, the same way test-supervisor.ps1 stubs it: Get-ClaudeQuota
# calls it only on the (untested here) unexpected-response-shape/network-failure paths, which
# the cache-hit checks below never reach, but defining it keeps the function's own definition
# self-contained regardless. Get-ClaudeQuota also calls Write-Utf8File and Invoke-RestMethod
# only past the cache-hit early-returns exercised below, so a live network call/credentials
# file is never required for this script to pass.
function Write-Log([string]$Message) { }

foreach ($fn in @("ConvertFrom-ClaudeUsageResponse", "Get-ClaudeQuota")) {
    try {
        . ([scriptblock]::Create((Get-FunctionSource $supervisorPath $fn)))
    } catch {
        Write-Host "FAIL Function extraction: $fn (scripts/agent-supervisor.ps1) -- unexpected error: $($_.Exception.Message)"
        $script:failCount++
    }
}

# ----------------------------------------------------------------------------- ConvertFrom-ClaudeUsageResponse: fixture
try {
    if (-not (Test-Path $fixturePath)) { throw "fixture not found: $fixturePath" }
    $fixture = Get-Content -Raw -Path $fixturePath -Encoding utf8 | ConvertFrom-Json
    $result = @(ConvertFrom-ClaudeUsageResponse $fixture)

    Test-Result "ConvertFrom-ClaudeUsageResponse: fixture yields exactly two quota entries" ($result.Count -eq 2)

    $fiveHour = $result | Where-Object { $_.label -eq "5 h" } | Select-Object -First 1
    Test-Result "ConvertFrom-ClaudeUsageResponse: '5 h' entry has usedPercent 42 and remaining 58" (
        $fiveHour -and $fiveHour.usedPercent -eq 42 -and $fiveHour.remaining -eq 58
    )
    Test-Result "ConvertFrom-ClaudeUsageResponse: '5 h' entry's resetsAt is a parseable ISO-8601 date" (
        $fiveHour -and $fiveHour.resetsAt -and ([datetime]::Parse([string]$fiveHour.resetsAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)).Year -eq 2026
    )

    $sevenDay = $result | Where-Object { $_.label -eq "7 d" } | Select-Object -First 1
    Test-Result "ConvertFrom-ClaudeUsageResponse: '7 d' entry has usedPercent 18" (
        $sevenDay -and $sevenDay.usedPercent -eq 18
    )
} catch {
    Write-Host "FAIL ConvertFrom-ClaudeUsageResponse: fixture -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- ConvertFrom-ClaudeUsageResponse: numeric resets_at
try {
    $numericResponse = [pscustomobject]@{
        five_hour = [pscustomobject]@{ utilization = 5; resets_at = 1791158400 }
        seven_day = [pscustomobject]@{ utilization = 9; resets_at = 1791500000 }
    }
    $numericResult = @(ConvertFrom-ClaudeUsageResponse $numericResponse)
    $fiveHourNumeric = $numericResult | Where-Object { $_.label -eq "5 h" } | Select-Object -First 1
    Test-Result "ConvertFrom-ClaudeUsageResponse: a numeric Unix-seconds resets_at normalizes to ISO-8601" (
        $fiveHourNumeric -and $fiveHourNumeric.resetsAt -and ([datetime]::Parse([string]$fiveHourNumeric.resetsAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)).Year -gt 2000
    )
} catch {
    Write-Host "FAIL ConvertFrom-ClaudeUsageResponse: numeric resets_at -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- ConvertFrom-ClaudeUsageResponse: empty/malformed
try {
    $emptyResult = @(ConvertFrom-ClaudeUsageResponse ([pscustomobject]@{}))
    Test-Result "ConvertFrom-ClaudeUsageResponse: an object missing five_hour/seven_day yields no quotas, without throwing" ($emptyResult.Count -eq 0)

    $nullResult = @(ConvertFrom-ClaudeUsageResponse $null)
    Test-Result "ConvertFrom-ClaudeUsageResponse: `$null input yields no quotas, without throwing" ($nullResult.Count -eq 0)

    $noUtilizationResult = @(ConvertFrom-ClaudeUsageResponse ([pscustomobject]@{ five_hour = [pscustomobject]@{ resets_at = "2026-01-01T00:00:00Z" } }))
    Test-Result "ConvertFrom-ClaudeUsageResponse: a window missing .utilization is skipped, without throwing" ($noUtilizationResult.Count -eq 0)
} catch {
    Write-Host "FAIL ConvertFrom-ClaudeUsageResponse: empty/malformed -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Get-ClaudeQuota: fresh cache
# Deliberately at top-level scope (not inside a function/scriptblock), the same way
# scripts/test-copilot-quota.ps1 sets $statePath for Get-CopilotQuota: Get-ClaudeQuota, as
# extracted from agent-supervisor.ps1, reads the bare $statePath variable via its own lexical
# (definition-site) scope chain, which is this script's top-level scope.
try {
    $tempStateDir = Join-Path $env:TEMP "test-claude-quota-state-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $tempStateDir -ErrorAction Stop | Out-Null
    try {
        $statePath = $tempStateDir
        $cachePath = Join-Path $tempStateDir "claude-quota-cache.json"

        # Quota values that could not have come from converting the fixture above (fixture is
        # 42/18): if Get-ClaudeQuota ignored the cache and re-derived from the fixture (or hit
        # the live network, unreachable here), these exact values would not come back.
        $seeded = [pscustomobject]@{
            fetchedAt    = (Get-Date).AddSeconds(-10).ToString("o")
            quotas       = @(@{ label = "Bogus"; usedPercent = 77; remaining = 23; total = 100; resetsAt = "2099-01-01T00:00:00.0000000"; source = "test-cache" })
            backoffUntil = $null
        }
        [System.IO.File]::WriteAllText($cachePath, ($seeded | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

        $cachedQuota = @(Get-ClaudeQuota)
        Test-Result "Get-ClaudeQuota: a fresh (10s-old) cache is returned unchanged, with no network call" (
            $cachedQuota.Count -eq 1 -and (@($cachedQuota)[0].label -eq "Bogus") -and (@($cachedQuota)[0].usedPercent -eq 77)
        )
    } finally {
        Remove-Item -Recurse -Force $tempStateDir -ErrorAction SilentlyContinue
    }
} catch {
    Write-Host "FAIL Get-ClaudeQuota: fresh cache -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Get-ClaudeQuota: backoff
try {
    $tempStateDir2 = Join-Path $env:TEMP "test-claude-quota-state-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $tempStateDir2 -ErrorAction Stop | Out-Null
    try {
        $statePath = $tempStateDir2
        $cachePath = Join-Path $tempStateDir2 "claude-quota-cache.json"

        # fetchedAt is stale (well past the 5-minute freshness window) but backoffUntil is still
        # 10 minutes in the future: a live 429 backoff must win over the staleness check and
        # still return the cache without calling out.
        $seeded = [pscustomobject]@{
            fetchedAt    = (Get-Date).AddHours(-2).ToString("o")
            quotas       = @(@{ label = "Bogus"; usedPercent = 88; remaining = 12; total = 100; resetsAt = "2099-01-01T00:00:00.0000000"; source = "test-cache" })
            backoffUntil = (Get-Date).AddMinutes(10).ToString("o")
        }
        [System.IO.File]::WriteAllText($cachePath, ($seeded | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

        $backoffQuota = @(Get-ClaudeQuota)
        Test-Result "Get-ClaudeQuota: an active backoffUntil returns the cache unchanged, with no network call" (
            $backoffQuota.Count -eq 1 -and (@($backoffQuota)[0].label -eq "Bogus") -and (@($backoffQuota)[0].usedPercent -eq 88)
        )
    } finally {
        Remove-Item -Recurse -Force $tempStateDir2 -ErrorAction SilentlyContinue
    }
} catch {
    Write-Host "FAIL Get-ClaudeQuota: backoff -- unexpected error: $($_.Exception.Message)"
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
