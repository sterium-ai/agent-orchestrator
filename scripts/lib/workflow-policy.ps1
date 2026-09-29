# Pure policy helpers. No GitHub, process launch, or filesystem mutations.
function Get-LegacyRevisionCount([int]$Number, [hashtable]$State, [string[]]$LogLines) {
    # Read the old append-only log once, before persisting the new cumulative field.
    $launches = 0
    $refusals = 0
    foreach ($line in $LogLines) {
        if ($line -match "\[issue-$Number-revise-\d+(?:-run-[a-f0-9]+)?\] launching") { $launches++ }
        if ($line -match "\[issue-$Number-revise-\d+(?:-run-[a-f0-9]+)?\].* is out of quota") { $refusals++ }
    }
    return [Math]::Max([int]$State.revisions, [Math]::Max(0, $launches - $refusals))
}

function Get-FindingStreaks([string[]]$Current, [object[]]$Previous) {
    foreach ($c in $Current) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        $repeats = 0
        foreach ($p in $Previous) {
            if ($p -and -not [string]::IsNullOrWhiteSpace([string]$p.text) -and
                (Test-RuleSimilarity -RuleA $c -RuleB ([string]$p.text) -Threshold 0.6)) {
                $repeats = [Math]::Max($repeats, [int]$p.repeats + 1)
            }
        }
        [pscustomobject]@{text=$c; repeats=$repeats}
    }
}

function Get-TaskContractFailures([string]$Body) {
    # Catch contradictory machine-readable dependencies, not arbitrary prose semantics.
    $fields = @([regex]::Matches($Body, '(?im)^\s*Blocked by:\s*(.+)$'))
    if ($fields.Count -gt 1) {
        $declared = @([regex]::Matches($fields[0].Groups[1].Value, '#\d+') | ForEach-Object { $_.Value })
        foreach ($field in $fields | Select-Object -Skip 1) {
            $extra = @([regex]::Matches($field.Groups[1].Value, '#\d+') | ForEach-Object { $_.Value } | Where-Object { $_ -notin $declared })
            if ($extra.Count) { return "Conflicting Blocked by fields: dependencies $($extra -join ', ') appear only in prose. Put the real prerequisites in the first field and remove contradictory duplicate fields." }
        }
    }
}
