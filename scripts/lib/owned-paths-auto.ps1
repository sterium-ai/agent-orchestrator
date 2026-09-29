# Pure, dot-sourceable helpers that widen a task's "## Owned paths" list with the files its owned
# paths imply (tests that reference them, companion files, file budgets). No dependency on
# agent-supervisor.ps1, `gh`, or any other script's state.
#
# Everything project-specific comes from an ownership rule set (see New-OwnershipRules and the
# "ownership" section of agent-orchestrator.example.json). With the default, empty rule set the
# only widening left is the optional file-budget rule, which is inert unless the budgets file
# exists in the worktree.

# Normalises the "ownership" section of the configuration (a PSCustomObject from ConvertFrom-Json,
# a hashtable, or $null) into a hashtable with every key present.
#   testDirectory      repo-relative folder whose files are scanned for references to owned paths
#   testFilter         file filter inside testDirectory (non-recursive), e.g. "*.test.js"
#   pathAliases        [{ from; to }]: extra spellings a test may use for a path
#                      (e.g. from "game/" to "res://" for a Godot project)
#   companions         [{ when; add }]: when an owned path matches the regex `when`, `add` is owned too
#   budgetsFile        repo-relative JSON file mapping a file to its maximum line count ("" = off)
#   decisionsDirectory where design decisions live; owned together with a budgeted file
#   protectedPaths     path prefixes no task may touch and no rescope may grant
#   generatedFiles     regexes for generated files that are restored when a task does not own them
function New-OwnershipRules {
    param($Config)
    $rules = @{
        testDirectory      = ''
        testFilter         = '*'
        pathAliases        = @()
        companions         = @()
        budgetsFile        = 'docs/architecture/core-budgets.json'
        decisionsDirectory = 'docs/decisions/'
        protectedPaths     = @()
        generatedFiles     = @()
    }
    if ($null -eq $Config) { return $rules }
    foreach ($key in @($rules.Keys)) {
        $value = $null
        if ($Config -is [hashtable]) { if ($Config.ContainsKey($key)) { $value = $Config[$key] } }
        elseif ($Config.PSObject.Properties[$key]) { $value = $Config.$key }
        if ($null -eq $value) { continue }
        if ($rules[$key] -is [array]) { $rules[$key] = @($value) } else { $rules[$key] = [string]$value }
    }
    return $rules
}

function Get-OwnershipCompareKey([string]$Path) {
    return ($Path -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
}

# Every spelling under which a test may refer to a repo-relative path: the path itself plus one
# form per matching alias ("game/scripts/x.gd" -> "res://scripts/x.gd"). A trailing slash is kept.
function ConvertTo-AliasedPaths {
    param(
        [Parameter(Mandatory = $true)][string]$OwnedPath,
        [AllowEmptyCollection()][object[]]$Aliases = @()
    )
    $normalized = ($OwnedPath -replace '\\', '/').TrimStart('/')
    $forms = @($normalized)
    foreach ($alias in @($Aliases)) {
        if (-not $alias) { continue }
        $from = [string]$(if ($alias -is [hashtable]) { $alias['from'] } else { $alias.from })
        $to = [string]$(if ($alias -is [hashtable]) { $alias['to'] } else { $alias.to })
        if (-not $from) { continue }
        if ($normalized.StartsWith($from, [System.StringComparison]::OrdinalIgnoreCase)) {
            $forms += $to + $normalized.Substring($from.Length)
        }
    }
    return $forms
}

# Returns an ordered array of [pscustomobject]@{ Path; Marker } for every path that must be
# appended to $OwnedPaths (never mutating $OwnedPaths itself, and never duplicating an entry
# already present in it).
function Get-AutoAddedOwnedPaths {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$OwnedPaths,

        [Parameter(Mandatory = $true)]
        [string]$WorktreeRoot,

        [hashtable]$Rules = (New-OwnershipRules $null)
    )

    $OwnedPaths = @($OwnedPaths | Where-Object { $_ })
    $ownedKeys = @($OwnedPaths | ForEach-Object { Get-OwnershipCompareKey $_ })
    $addedKeys = New-Object System.Collections.Generic.HashSet[string]
    $result = New-Object System.Collections.Generic.List[object]

    function Add-AutoPath {
        param([string]$Path, [string]$Marker)
        $key = Get-OwnershipCompareKey $Path
        if ($ownedKeys -contains $key) { return }
        if (-not $addedKeys.Add($key)) { return }
        $result.Add([pscustomobject]@{ Path = $Path; Marker = $Marker })
    }

    # ---- a. Tests that reference an owned path ----
    $testDirRel = ([string]$Rules.testDirectory -replace '\\', '/').Trim('/')
    if ($testDirRel) {
        $testsDir = Join-Path $WorktreeRoot ($testDirRel -replace '/', '\')
        $filter = if ($Rules.testFilter) { [string]$Rules.testFilter } else { '*' }
        $testFiles = @()
        if (Test-Path -LiteralPath $testsDir) {
            # Non-recursive on purpose: fixtures and helpers in subfolders are not tests.
            $testFiles = @(Get-ChildItem -LiteralPath $testsDir -Filter $filter -File -ErrorAction SilentlyContinue | Sort-Object Name)
        }
        $testText = @{}
        foreach ($tf in $testFiles) { $testText[$tf.FullName] = Get-Content -LiteralPath $tf.FullName -Raw -ErrorAction SilentlyContinue }
        foreach ($entry in $OwnedPaths) {
            $forms = @(ConvertTo-AliasedPaths -OwnedPath $entry -Aliases $Rules.pathAliases)
            foreach ($tf in $testFiles) {
                $text = $testText[$tf.FullName]
                if (-not $text) { continue }
                foreach ($form in $forms) {
                    if ($form -and $text.Contains($form)) {
                        Add-AutoPath -Path "$testDirRel/$($tf.Name)" -Marker "(auto: asserts on $entry)"
                        break
                    }
                }
            }
        }
    }

    # ---- b. Companion files ----
    foreach ($companion in @($Rules.companions)) {
        if (-not $companion) { continue }
        $when = [string]$(if ($companion -is [hashtable]) { $companion['when'] } else { $companion.when })
        $add = [string]$(if ($companion -is [hashtable]) { $companion['add'] } else { $companion.add })
        if (-not $when -or -not $add) { continue }
        foreach ($entry in $OwnedPaths) {
            if (($entry -replace '\\', '/') -match $when) {
                Add-AutoPath -Path $add -Marker "(auto: required with $entry)"
                break
            }
        }
    }

    # ---- c. File budgets ----
    # A task that owns a budgeted file may have to raise its cap, and raising a cap is a design
    # decision that needs a decision record in the same change. Owning both up front avoids a
    # `## Blocked` stop on the first revision.
    $budgetsRel = ([string]$Rules.budgetsFile -replace '\\', '/').Trim('/')
    if ($budgetsRel) {
        $budgetsPath = Join-Path $WorktreeRoot ($budgetsRel -replace '/', '\')
        if (Test-Path -LiteralPath $budgetsPath) {
            $budgetKeys = @()
            try {
                $budgets = Get-Content -LiteralPath $budgetsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $budgetKeys = @($budgets.PSObject.Properties.Name | Where-Object { $_ -and -not $_.StartsWith('_') } | ForEach-Object { Get-OwnershipCompareKey $_ })
            } catch { $budgetKeys = @() }
            $budgetTrigger = $null
            foreach ($entry in $OwnedPaths) {
                if ($budgetKeys -contains (Get-OwnershipCompareKey $entry)) { $budgetTrigger = $entry; break }
            }
            if ($budgetTrigger) {
                Add-AutoPath -Path $budgetsRel -Marker "(auto: budget cap for $budgetTrigger)"
                if ($Rules.decisionsDirectory) {
                    Add-AutoPath -Path ([string]$Rules.decisionsDirectory) -Marker "(auto: decision record for raising the cap of $budgetTrigger)"
                }
            }
        }
    }

    return $result.ToArray()
}

# Renders the exact multi-line text to put under "## Owned paths": one bullet per original
# entry unchanged, followed by one auto-added bullet per Get-AutoAddedOwnedPaths result.
function Format-OwnedPathsSection {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$OwnedPaths,

        [Parameter(Mandatory = $true)]
        [string]$WorktreeRoot,

        [hashtable]$Rules = (New-OwnershipRules $null)
    )

    $lines = @($OwnedPaths | ForEach-Object { "- ``$_``" })
    $auto = @(Get-AutoAddedOwnedPaths -OwnedPaths $OwnedPaths -WorktreeRoot $WorktreeRoot -Rules $Rules)
    $lines += @($auto | ForEach-Object { "- ``$($_.Path)`` $($_.Marker)" })
    return ($lines -join "`n")
}

# Whether a repo-relative path is equal to, or lies under, an owned file or directory.
# Case-insensitive, slash-direction-insensitive.
function Test-PathCovered {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$OwnedPaths
    )

    $key = (($Path -replace '\\', '/') -replace '/+$', '').ToLowerInvariant()
    foreach ($owned in @($OwnedPaths)) {
        if (-not $owned) { continue }
        $ownedKey = (($owned -replace '\\', '/') -replace '/+$', '').ToLowerInvariant()
        if ($ownedKey -and ($ownedKey -eq $key -or $key.StartsWith($ownedKey + '/'))) {
            return $true
        }
    }
    return $false
}

# Generated files a task does not own, out of a list of changed repo-relative paths: paths that
# match one of the configured `generatedFiles` regexes and that no owned entry covers. Build and
# import tools often rewrite such files non-deterministically; the supervisor restores them to the
# branch base before it commits on the author's behalf, so the reviewer never sees the churn.
# This filter is the pure, testable half. With no patterns configured it selects nothing.
function Select-UnownedGeneratedPaths {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Paths,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$OwnedPaths,
        [AllowEmptyCollection()][string[]]$Patterns = @()
    )
    $result = New-Object System.Collections.Generic.List[string]
    $Patterns = @($Patterns | Where-Object { $_ })
    if ($Patterns.Count -eq 0) { return $result.ToArray() }
    foreach ($raw in @($Paths)) {
        if (-not $raw) { continue }
        $p = ($raw -replace '\\', '/').Trim()
        $isGenerated = $false
        foreach ($pattern in $Patterns) { if ($p -match $pattern) { $isGenerated = $true; break } }
        if (-not $isGenerated) { continue }
        if (Test-PathCovered -Path $p -OwnedPaths $OwnedPaths) { continue }
        $result.Add($p)
    }
    return $result.ToArray()
}
