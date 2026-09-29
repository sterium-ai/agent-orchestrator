# One bounded specialist correction, using the ordinary worker/push/review lifecycle.
function Queue-ExpertRecovery($Issue, [hashtable]$State, [string]$Kind, [string]$Failure, [string]$Worktree) {
    if (-not $ExpertRecoveryEnabled -or [int]$State.expertAttempts -ge 1 -or
        -not $Worktree -or -not (Test-Path -LiteralPath $Worktree)) { return $false }
    if ([IO.Path]::GetFullPath($Worktree).TrimEnd('\','/') -eq [IO.Path]::GetFullPath($root).TrimEnd('\','/')) { return $false }
    $stuck = $Kind -in @('the same finding was restated three rounds in a row', 'the revision ceiling was reached')
    if (-not $stuck -and [int]$State.repairs -lt $MaxRepairs) { return $false }
    if ($State.pendingPush) { return $false }
    $n = [int]$Issue.number
    $providers = Get-IssueProviders $Issue
    $provider = if ($providers.Author -eq 'claude') { 'claude' } else { 'codex' }
    $model = if ($provider -eq 'claude') { $ClaudeExpertModel } else { $CodexExpertModel }
    $parts = @("Expert recovery trigger: $Kind", (Limit-Text $Failure 6000 'trigger failure'))
    $parts += "Corrections so far: $([int]$State.totalRevisionAttempts); repairs: $([int]$State.repairs). Previous repair hint: " + (Limit-Text ([string]$State.repairHint) 3000 'repair hint')
    $objective = @(Get-IssueRefs (Get-Field $Issue.body 'Objective'))
    if ($objective.Count) { $parent = Get-Issue ([int]$objective[0]); if ($parent) { $parts += "Parent objective:`n" + (Limit-Text ([string]$parent.body) 6000 'objective') } }
    $parts += "Evidence directory: $statePath (read only). Read full relevant artifacts there if an excerpt is insufficient."
    try { $parts += Limit-Text (Read-Handoff $Worktree) 6000 'handoff' } catch { }
    $files = @(Get-ChildItem -LiteralPath $statePath -Filter "issue-$n.review-*.md" | Sort-Object LastWriteTime -Descending | Select-Object -First 3)
    $files += @(Get-Item -LiteralPath (Join-Path $statePath "issue-$n.acceptance.md") -ErrorAction SilentlyContinue)
    foreach ($file in $files) { $parts += "Evidence: $($file.FullName)`n" + (Limit-Text ([string](Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8)) 6000 'evidence') }
    $State.pendingRevision = @{ text=($parts -join "`n`n"); by='expert escalation'; expert=$true; provider=$provider; model=$model }
    $State.awaitingRevisionBy = $provider
    # Record intent before any provider swap or launch; a restart resumes the same correction.
    if (-not (Save-State $n $State)) { Report-Failure $Issue 'Could not save expert recovery intent; no expert launched.'; return $true }
    Comment $n "Supervisor: persistent blockage escalated to ``$model`` (medium), one correction session up to $ExpertTimeoutMinutes minutes with owner-authorized full local permissions (the CLI's permission-bypass mode). Existing commits and all review gates are preserved."
    return $true
}
