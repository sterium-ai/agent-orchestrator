# Pure, dot-sourceable helpers that give a hand-written task the same "## Owned paths" widening
# the planner applies to its own tasks (Format-OwnedPathsSection) -- before an author session is
# spent on it. Planner tasks are already widened, so for them this is a no-op.
#
# Why: tasks nobody ran through the planner (a reviewer's follow-up task, an owner rewrite) tend
# to miss the tests and companion files their owned files imply, and the omission is otherwise
# only discovered by a review round. The supervisor widens deterministically here, exactly like
# Repair-NestedAcceptanceCommands: a free repair that never costs an author or review round.
#
# No dependency on agent-supervisor.ps1, `gh`, or any other script's state. Requires
# scripts/lib/owned-paths-auto.ps1 to be dot-sourced first (New-OwnershipRules,
# Get-AutoAddedOwnedPaths, Test-PathCovered).

# Returns an ordered array of [pscustomobject]@{ Path; Marker } with everything a task body's
# ## Owned paths list is missing according to the ownership rules, skipping any path already
# covered by an owned directory. Empty for a planner task that was already widened.
function Get-TaskPreflightAdditions {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Body,

        [Parameter(Mandatory = $true)]
        [string]$WorktreeRoot,

        [Parameter(Mandatory = $true)]
        [int]$IssueNumber,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$OwnedPaths,

        [hashtable]$Rules = (New-OwnershipRules $null)
    )

    $OwnedPaths = @($OwnedPaths | Where-Object { $_ })
    $result = New-Object System.Collections.Generic.List[object]
    if ($OwnedPaths.Count -eq 0) { return $result.ToArray() }

    foreach ($auto in @(Get-AutoAddedOwnedPaths -OwnedPaths $OwnedPaths -WorktreeRoot $WorktreeRoot -Rules $Rules)) {
        if (Test-PathCovered -Path $auto.Path -OwnedPaths $OwnedPaths) { continue }
        $result.Add($auto)
    }

    return $result.ToArray()
}

# A repo-relative path as it appears in prose: at least one "/" and only path characters.
# Trailing punctuation is trimmed by the callers.
function Get-RepoPathPattern {
    return '(?<![\w/.\\:])((?:[A-Za-z0-9_\-][A-Za-z0-9_.\-]*/)+[A-Za-z0-9_.\-]*)'
}

function Get-TrimmedPathToken([string]$Token) {
    return $Token.TrimEnd('.', ',', ';', ':', ')', '`', "'", '"')
}

# Paths a task body itself declares off-limits, so a rescope never grants them: every path named
# in a "Do not modify / change / edit / touch ..." sentence (Non-goals, Goal, wherever it sits).
# A `## Blocked` report that names one of these is not a missing-ownership stop, it is a scope
# decision that belongs to the repair step or a person.
function Get-ForbiddenPathsFromBody {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Body)
    $result = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Body)) { return $result.ToArray() }
    $seen = New-Object System.Collections.Generic.HashSet[string]
    foreach ($sentence in [regex]::Matches($Body, '(?i)\bdo not (?:modify|change|edit|touch)\b([^\r\n]*)')) {
        foreach ($m in [regex]::Matches($sentence.Groups[1].Value, (Get-RepoPathPattern))) {
            $p = Get-TrimmedPathToken $m.Groups[1].Value
            if ($p -and $seen.Add($p.ToLowerInvariant())) { $result.Add($p) }
        }
    }
    return $result.ToArray()
}

# True when $Path is one of the prefixes itself or lies under it (prefixes may be files or directories).
function Test-PathUnderForbidden {
    param([string]$Path, [string[]]$Forbidden)
    $norm = $Path.TrimEnd('/').ToLowerInvariant()
    foreach ($f in @($Forbidden)) {
        if (-not $f) { continue }
        $fn = ($f -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
        if ($norm -eq $fn -or $norm.StartsWith($fn + '/')) { return $true }
    }
    return $false
}

# Repo-relative paths an author names in a `## Blocked` report ("needs src/core/x.js",
# "`docs/architecture/y.md` is not owned"), kept only when they exist in the worktree (file or
# directory) and no owned entry already covers them. Protected paths and the orchestrator's own
# scripts are never returned, and neither is a whole top-level folder. Deterministic input for
# the free rescope that would otherwise cost a repair session.
function Get-PathsNamedInBlockedReport {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$WorktreeRoot,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$OwnedPaths,
        [int]$Max = 8,
        # The task body: paths its own text forbids are never returned, and if the report names one
        # the whole report is returned empty (it is a scope decision, not a missing-ownership stop).
        [string]$TaskBody = '',
        [hashtable]$Rules = (New-OwnershipRules $null)
    )
    $result = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Text)) { return $result.ToArray() }
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $forbidden = @(Get-ForbiddenPathsFromBody -Body $TaskBody)
    $protected = @($Rules.protectedPaths | Where-Object { $_ })
    foreach ($m in [regex]::Matches($Text, (Get-RepoPathPattern))) {
        $candidate = Get-TrimmedPathToken $m.Groups[1].Value
        if (-not $candidate) { continue }
        if ($candidate -match '(^|/)(agent-supervisor|run-agent)\.ps1$') { continue }
        if (Test-PathUnderForbidden -Path $candidate -Forbidden $protected) { continue }
        $full = Join-Path $WorktreeRoot ($candidate -replace '/', '\')
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $rel = if ((Get-Item -LiteralPath $full) -is [System.IO.DirectoryInfo]) { $candidate.TrimEnd('/') + '/' } else { $candidate }
        # A whole top-level area (`src/`, `tests/`) is not a rescope.
        if ($rel.EndsWith('/') -and ($rel.TrimEnd('/').Split('/').Count -le 1)) { continue }
        if (Test-PathUnderForbidden -Path $rel -Forbidden $forbidden) { return @() }
        if (Test-PathCovered -Path $rel -OwnedPaths $OwnedPaths) { continue }
        if ($seen.Add($rel.ToLowerInvariant())) { $result.Add($rel) }
        if ($result.Count -ge $Max) { break }
    }
    return $result.ToArray()
}

# Returns the task body with the given additions appended as "- `path` (auto: ...)" bullets at
# the end of its ## Owned paths section, or $null when the body has no such section (a task
# without one is a contract defect for the repair step, not something to invent here).
function Add-OwnedPathsToBody {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Body,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Additions
    )

    if ($Additions.Count -eq 0) { return $Body }
    $section = [regex]::Match($Body, '(?ms)^##\s*Owned paths\s*\r?\n(.*?)(?=^##\s|\z)')
    if (-not $section.Success) { return $null }
    $bullets = @($Additions | ForEach-Object { "- ``$($_.Path)`` $($_.Marker)" })
    $existing = $section.Groups[1].Value.TrimEnd("`r", "`n")
    $newText = $existing + "`n" + ($bullets -join "`n") + "`n"
    # Keep the blank line that separated this section from the next heading, when there was one.
    if ($section.Groups[1].Value -match '\r?\n\s*\r?\n\s*\z') { $newText += "`n" }
    return $Body.Substring(0, $section.Groups[1].Index) + $newText + $Body.Substring($section.Groups[1].Index + $section.Groups[1].Length)
}
