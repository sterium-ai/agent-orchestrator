<#
.SYNOPSIS
Self-test for scripts/lib/owned-paths-auto.ps1 (New-OwnershipRules, ConvertTo-AliasedPaths,
Get-AutoAddedOwnedPaths, Format-OwnedPathsSection, Test-PathCovered,
Select-UnownedGeneratedPaths) and the companion Get-OwnedPaths in scripts/agent-supervisor.ps1.

.DESCRIPTION
Builds a throwaway worktree under $env:TEMP with sample test files and several planner-style
owned_paths arrays, then asserts the widened "## Owned paths" list follows the configured
ownership rules. Get-OwnedPaths is extracted from agent-supervisor.ps1 by AST so the supervisor's
own module-level code never runs.

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

# ----------------------------------------------------------------------------- rules
$defaults = New-OwnershipRules $null
Test-Result "New-OwnershipRules: defaults have no test directory, companions or protected paths" `
    (-not $defaults.testDirectory -and @($defaults.companions).Count -eq 0 -and @($defaults.protectedPaths).Count -eq 0 -and @($defaults.generatedFiles).Count -eq 0)
Test-Result "New-OwnershipRules: the budgets file defaults to docs/architecture/core-budgets.json" ($defaults.budgetsFile -eq 'docs/architecture/core-budgets.json')
$fromJson = New-OwnershipRules ('{ "testDirectory": "tests", "protectedPaths": ["vendor/"], "budgetsFile": "" }' | ConvertFrom-Json)
Test-Result "New-OwnershipRules: values from parsed JSON override the defaults" ($fromJson.testDirectory -eq 'tests' -and @($fromJson.protectedPaths) -contains 'vendor/' -and $fromJson.budgetsFile -eq '')
Test-Result "New-OwnershipRules: keys absent from the JSON keep their defaults" ($fromJson.testFilter -eq '*' -and $fromJson.decisionsDirectory -eq 'docs/decisions/')

# ----------------------------------------------------------------------------- aliases
$aliases = @(@{ from = 'src/'; to = '@/' })
$forms = @(ConvertTo-AliasedPaths -OwnedPath 'src/core/cart.js' -Aliases $aliases)
Test-Result "ConvertTo-AliasedPaths: returns the path itself first" ($forms[0] -eq 'src/core/cart.js')
Test-Result "ConvertTo-AliasedPaths: adds the aliased spelling" ($forms -contains '@/core/cart.js')
Test-Result "ConvertTo-AliasedPaths: back-slashes are normalised" (@(ConvertTo-AliasedPaths -OwnedPath 'src\core\cart.js' -Aliases $aliases) -contains '@/core/cart.js')
Test-Result "ConvertTo-AliasedPaths: a path outside the alias prefix gets no alias" (@(ConvertTo-AliasedPaths -OwnedPath 'docs/a.md' -Aliases $aliases).Count -eq 1)
Test-Result "ConvertTo-AliasedPaths: a directory keeps its trailing slash" (@(ConvertTo-AliasedPaths -OwnedPath 'src/core/' -Aliases $aliases) -contains '@/core/')

# ----------------------------------------------------------------------------- fixture worktree
$testRoot = Join-Path $env:TEMP "test-owned-paths-auto-$([Guid]::NewGuid().ToString('N'))"
$testsDir = Join-Path $testRoot "tests"
New-Item -ItemType Directory -Force -Path (Join-Path $testsDir "fixtures") | Out-Null
Set-Content -Path (Join-Path $testsDir "cart.test.js") -Encoding utf8 -Value "import { add } from '@/core/cart.js';"
Set-Content -Path (Join-Path $testsDir "plain.test.js") -Encoding utf8 -Value "// asserts against src/core/prices.js"
Set-Content -Path (Join-Path $testsDir "unrelated.test.js") -Encoding utf8 -Value "// asserts against src/other/thing.js"
Set-Content -Path (Join-Path $testsDir "notes.md") -Encoding utf8 -Value "mentions src/core/cart.js but is not a test"
Set-Content -Path (Join-Path $testsDir "fixtures\nested.test.js") -Encoding utf8 -Value "// src/core/cart.js in a fixture"

$rules = New-OwnershipRules @{
    testDirectory = 'tests'
    testFilter    = '*.test.js'
    pathAliases   = $aliases
    companions    = @(@{ when = '^src/db/'; add = 'tests/fixtures/' }, @{ when = '^src/db/migrations/'; add = 'docs/schema.md' })
}

try {
    $autoA = @(Get-AutoAddedOwnedPaths -OwnedPaths @('src/core/cart.js') -WorktreeRoot $testRoot -Rules $rules)
    $matchA = $autoA | Where-Object { $_.Path -eq 'tests/cart.test.js' }
    Test-Result "tests: a test referencing the owned file through an alias is added" ($null -ne $matchA) "got: $(($autoA | ForEach-Object { $_.Path }) -join ', ')"
    Test-Result "tests: the marker names the owned path" ($null -ne $matchA -and $matchA.Marker -eq '(auto: asserts on src/core/cart.js)')
    Test-Result "tests: an unrelated test is not added" (@($autoA | Where-Object { $_.Path -eq 'tests/unrelated.test.js' }).Count -eq 0)
    Test-Result "tests: files outside the test filter are not added" (@($autoA | Where-Object { $_.Path -eq 'tests/notes.md' }).Count -eq 0)
    Test-Result "tests: subfolders of the test directory are not scanned" (@($autoA | Where-Object { $_.Path -like '*nested*' }).Count -eq 0)

    $autoB = @(Get-AutoAddedOwnedPaths -OwnedPaths @('src/core/prices.js') -WorktreeRoot $testRoot -Rules $rules)
    Test-Result "tests: a test naming the plain repo-relative path is added" (@($autoB | Where-Object { $_.Path -eq 'tests/plain.test.js' }).Count -eq 1)

    Test-Result "tests: without a test directory configured nothing is scanned" `
        (@(Get-AutoAddedOwnedPaths -OwnedPaths @('src/core/cart.js') -WorktreeRoot $testRoot).Count -eq 0)

    $autoC = @(Get-AutoAddedOwnedPaths -OwnedPaths @('src/db/migrations/0007.sql') -WorktreeRoot $testRoot -Rules $rules)
    Test-Result "companions: a matching owned path adds its companion" (@($autoC | Where-Object { $_.Path -eq 'tests/fixtures/' -and $_.Marker -eq '(auto: required with src/db/migrations/0007.sql)' }).Count -eq 1)
    Test-Result "companions: every matching rule applies" (@($autoC | Where-Object { $_.Path -eq 'docs/schema.md' }).Count -eq 1)
    $autoD = @(Get-AutoAddedOwnedPaths -OwnedPaths @('src/db/migrations/0007.sql', 'tests/fixtures/', 'docs/schema.md') -WorktreeRoot $testRoot -Rules $rules)
    Test-Result "companions: a path already owned is never duplicated" ($autoD.Count -eq 0) "got: $(($autoD | ForEach-Object { $_.Path }) -join ', ')"

    $sectionA = Format-OwnedPathsSection -OwnedPaths @('src/core/cart.js') -WorktreeRoot $testRoot -Rules $rules
    $expectedSectionA = "- ``src/core/cart.js```n- ``tests/cart.test.js`` (auto: asserts on src/core/cart.js)"
    Test-Result "Format-OwnedPathsSection: original bullet unchanged, auto bullet appended with marker" ($sectionA -eq $expectedSectionA) "got: $sectionA"

    $body = @"
Provider: claude
Reviewer: codex

## Owned paths
$sectionA

## Acceptance checks
- something
"@
    $roundTripped = @(Get-OwnedPaths $body)
    Test-Result "Get-OwnedPaths: a plain bullet round-trips to the bare path" ($roundTripped -contains 'src/core/cart.js')
    Test-Result "Get-OwnedPaths: a bullet with a trailing (auto: ...) annotation round-trips to the bare path" ($roundTripped -contains 'tests/cart.test.js')
    Test-Result "Get-OwnedPaths: the annotation text itself is not returned" (-not ($roundTripped | Where-Object { $_ -match 'auto:' }))

    # File budgets: inert without the budgets file, active with it.
    Test-Result "budgets: inert while the budgets file does not exist" (@($autoA | Where-Object { $_.Path -like '*core-budgets.json' }).Count -eq 0)
    $budgetsDir = Join-Path $testRoot "docs\architecture"
    New-Item -ItemType Directory -Force -Path $budgetsDir | Out-Null
    Set-Content -Path (Join-Path $budgetsDir "core-budgets.json") -Encoding utf8 -Value '{ "_note": "caps", "src/core/engine.js": 800 }'
    $autoE = @(Get-AutoAddedOwnedPaths -OwnedPaths @('src/core/engine.js') -WorktreeRoot $testRoot -Rules $rules)
    Test-Result "budgets: owning a capped file adds the budgets file with a budget marker" `
        (@($autoE | Where-Object { $_.Path -eq 'docs/architecture/core-budgets.json' -and $_.Marker -eq '(auto: budget cap for src/core/engine.js)' }).Count -eq 1)
    Test-Result "budgets: owning a capped file adds the decisions directory" (@($autoE | Where-Object { $_.Path -eq 'docs/decisions/' }).Count -eq 1)
    $autoF = @(Get-AutoAddedOwnedPaths -OwnedPaths @('src/core/engine.js', 'docs/decisions/', 'docs/architecture/core-budgets.json') -WorktreeRoot $testRoot -Rules $rules)
    Test-Result "budgets: nothing is added when both are already owned" ($autoF.Count -eq 0)
    Test-Result "budgets: owning an uncapped file adds no budget entries" `
        (@(Get-AutoAddedOwnedPaths -OwnedPaths @('src/core/other.js') -WorktreeRoot $testRoot -Rules $rules | Where-Object { $_.Path -like 'docs/*' }).Count -eq 0)
    $noBudgets = New-OwnershipRules @{ budgetsFile = '' }
    Test-Result "budgets: an empty budgetsFile switches the rule off" (@(Get-AutoAddedOwnedPaths -OwnedPaths @('src/core/engine.js') -WorktreeRoot $testRoot -Rules $noBudgets).Count -eq 0)
} catch {
    Write-Host "FAIL Owned-paths-auto checks -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
} finally {
    Remove-Item -Recurse -Force $testRoot -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------------- coverage
Test-Result "Test-PathCovered: a file under an owned directory is covered" (Test-PathCovered -Path 'tests/a.test.js' -OwnedPaths @('tests/'))
Test-Result "Test-PathCovered: an exactly owned file is covered, case-insensitively" (Test-PathCovered -Path 'SRC/A.js' -OwnedPaths @('src/a.js'))
Test-Result "Test-PathCovered: a sibling with a shared prefix is not covered" (-not (Test-PathCovered -Path 'tests-old/a.js' -OwnedPaths @('tests')))
Test-Result "Test-PathCovered: back-slashes are normalised" (Test-PathCovered -Path 'src\core\a.js' -OwnedPaths @('src/core/'))

# ----------------------------------------------------------------------------- unowned generated files
$patterns = @('\.snap$', '^src/generated/')
$genOwned = @('src/ui/button.js', 'src/ui/__snapshots__/')
$genChanged = @(
    'src/ui/__snapshots__/button.test.js.snap',
    'src/pages/__snapshots__/home.test.js.snap',
    'src/generated/api.ts',
    'src\generated\types.ts',
    'src/ui/button.js',
    'docs/readme.md'
)
$genSel = @(Select-UnownedGeneratedPaths -Paths $genChanged -OwnedPaths $genOwned -Patterns $patterns)
Test-Result "generated: an unowned file matching a pattern is selected" ($genSel -contains 'src/pages/__snapshots__/home.test.js.snap') ("got: " + ($genSel -join ', '))
Test-Result "generated: a back-slashed path is normalised and selected" ($genSel -contains 'src/generated/types.ts')
Test-Result "generated: a generated file under an owned directory is not selected" (-not ($genSel -contains 'src/ui/__snapshots__/button.test.js.snap'))
Test-Result "generated: a source file is never selected" (-not ($genSel -contains 'src/ui/button.js'))
Test-Result "generated: a path matching no pattern is not selected" (-not ($genSel -contains 'docs/readme.md'))
Test-Result "generated: with no patterns configured nothing is selected" (@(Select-UnownedGeneratedPaths -Paths $genChanged -OwnedPaths @()).Count -eq 0)
Test-Result "generated: empty input yields nothing" (@(Select-UnownedGeneratedPaths -Paths @() -OwnedPaths @() -Patterns $patterns).Count -eq 0)

# ----------------------------------------------------------------------------- summary
Write-Host ""
if ($script:failCount -gt 0) {
    Write-Host "SUMMARY: $script:failCount check(s) FAILED"
    exit 1
} else {
    Write-Host "SUMMARY: all checks passed"
    exit 0
}
