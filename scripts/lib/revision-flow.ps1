# Revision dispatch is shared by review rejections and repaired task contracts.
# State is durable before agent launch; a reviewer is still required after push.
function Invoke-TaskRevision {
    param($Issue, [hashtable]$st, [string]$worktree, [string]$branch,
          [string]$author, [int]$round, [int]$ceiling, [string]$reviewText,
          [string]$verdictBy, [string]$acceptanceReport, [string]$reasoning)
    $n = [int]$Issue.number
    $expert = [bool]($st.pendingRevision -and $st.pendingRevision.expert)
    if ($expert -and -not $ExpertRecoveryEnabled) { Report-Failure $Issue 'Expert recovery is disabled; queued intent is preserved but no privileged session will start.'; return }
    if (-not $expert -and [int]$st.totalRevisionAttempts -ge $MaxTotalRevisions) {
        if (Queue-ExpertRecovery $Issue $st 'the revision ceiling was reached' $reviewText $worktree) { return }
    }
    # Owed work survives a quota wait even when this was a fresh review rejection.
    if (-not $expert) { $st.pendingRevision = @{ text = $reviewText; by = $verdictBy } }
    if ($expert) {
        $author = [string]$st.pendingRevision.provider
        $providers = Get-IssueProviders $Issue
        if ($author -notin @('claude','codex')) { Report-Failure $Issue 'Invalid expert provider; no session launched.'; return }
        # Copilot work transfers explicitly to Codex; never let an effective author review itself.
        if ($providers.Author -ne $author -or $providers.Reviewer -eq $author) {
            $independent = if ($author -eq 'codex') { 'claude' } else { 'codex' }
            if (-not (Set-IssueProviders $Issue $author $independent)) { return }
        }
    }
    $st.awaitingRevisionBy = $author
    if (-not (Save-State $n $st)) {
        Report-Failure $Issue "Could not save the pending correction; no agent dispatched."
        return
    }
    if (-not (Test-ProviderUsable $author)) { return }
    if (($expert -and [int]$st.expertAttempts -ge 1) -or (-not $expert -and $st.totalRevisionAttempts -ge $MaxTotalRevisions)) {
        Report-Failure $Issue "Cumulative revision limit ($MaxTotalRevisions) reached. Commits are preserved; diagnose or split the task before explicitly granting more attempts."
        return
    }
    $st.totalRevisionAttempts = [int]$st.totalRevisionAttempts + 1
    if ($expert) {
        $st.expertAttempts = [int]$st.expertAttempts + 1
        $st.lastReviewedSha = $null; $st.lastVerdict = $null
        $st.lastAutoFailureSha = $null; $st.lastAutoFailureSignature = $null
        $st.findingStreaks = @(); $st.restatedRounds = 0
    }
    $st.revisions = $round
    # Persist "a revision is in flight and its result must be pushed before the next review" BEFORE
    # the revision worker is even launched, not after it returns. If the supervisor stops or
    # restarts at any point from here on -- while the worker is still running, or after it exits
    # but before the push below lands -- the remote PR still shows the OLDER, just-rejected code.
    # A restart in that window used to leave no trace of any of this: pendingPush was only written
    # after Invoke-Agent returned, so a crash mid-revision produced neither a live-worker record
    # useful past that point nor a pendingPush flag, and the next Invoke-Review call would launch a
    # brand-new review round against the local worktree while the remote PR stayed on the rejected
    # code -- an approval would then have nothing correct to merge and the mismatch check below
    # would defer forever. Setting the flag first means: on restart, the live-worker check above
    # (Get-LiveWorkerForIssue) still runs before this flag is ever consulted, so a still-running
    # worker is never treated as done; and once the worker is confirmed gone, the pendingPush
    # branch at the top of this function pushes its result before any new review is attempted.
    $st.pendingPush = $true
    # The real next step is now "the AUTHOR revises", not "a reviewer reads". Persisted so the
    # main loop gates this issue on the author's availability (see Test-ReviewRunnable): while
    # the issue stays labelled agent-review, a reviewer with quota is no reason to enter here
    # and spend the author's paused allowance on another immediate refusal.
    $st.awaitingRevisionBy = $author
    if (-not (Save-State $n $st)) {
        # The revision worker must not be launched at all if this can't be made durable: without
        # it on disk, a crash during (or right after) the revision would leave no trace that a
        # push is owed, and a later Invoke-Review would review the local worktree while the
        # remote PR still shows the just-rejected code -- exactly the gap this flag exists to
        # close. Failing the task is safer than launching a worker whose outcome recovery could
        # not later distinguish from "already pushed".
        Report-Failure $Issue "could not durably record that a revision was about to start (state file write failed); not launching the revision worker without that guarantee"
        return
    }
    Comment $n "Supervisor: ``$verdictBy`` requested changes (round $round). Sending back to ``$author`` for revision."
    # A `## Blocked` section already acted on for this commit (the owner fixed the cause and
    # relabelled) is stale now. Remove it before the author is relaunched, so a new commit made
    # with the old section still in the handoff cannot fail the task as "blocked" a second time.
    try {
        $handoffFile = Join-Path $worktree ".agent-state\HANDOFF.md"
        if ((Test-Path $handoffFile) -and (Get-HandoffBlock ([string](Get-Content -Raw $handoffFile -Encoding utf8)))) {
            $stale = [string](Get-Content -Raw $handoffFile -Encoding utf8)
            $cleaned = [regex]::Replace($stale, '(?ims)^[ \t]*##[ \t]*Blocked[ \t]*\r?\n.*?(?=^[ \t]*##[ \t]|\z)', '')
            Write-Utf8File $handoffFile $cleaned
            Write-Log "Issue #${n}: removed the already-handled ``## Blocked`` section from the handoff before relaunching ``$author``"
        }
    } catch { Write-Log "Issue #${n}: could not clean the stale Blocked section: $($_.Exception.Message)" }
    $revision = @"

## Revision requested (round $round of $ceiling)

Your previous commits on this branch were examined and changes were requested. Do not start
over; build on the existing commits. Run the failing acceptance commands yourself when your
sandbox allows it, read their FULL output, fix what it shows, and run them again before handing
off; quote the real output. The supervisor re-runs them on the host after you commit, as the
authoritative result.

For each blocking finding below, fix the REQUIREMENT behind it, not the sentence that names it.
These do not count as fixes and will be sent back: a fallback where the behaviour itself was
requested; a check at the point of the symptom instead of at its origin; a special case for the
one instance the reviewer named while the same fault stays elsewhere. Compare your change with
the finding's ``fix`` text before committing.

Then add to .agent-state/HANDOFF.md a section ``## Revision response`` with exactly one line per
blocking finding, in this shape:

    <finding, a few words> -> <what you changed, file and function> -> <why that resolves the requirement, not just the complaint>

A finding you will not act on gets ``<finding> -> disputed: <one sentence why>`` instead; the
reviewer decides whether the reason holds. A finding you CANNOT act on (a port or lock on the
host, a command in the task body that can never pass, a file outside your owned paths) is not
something to work around: write the ``## Blocked`` section described in the rules above and
commit nothing cosmetic. If the handoff still carries a ``## Blocked`` section from an earlier
round whose cause has since been fixed, delete it.

$reviewText
$(if ($acceptanceReport -and $verdictBy -ne "automatic pre-review checks") { "`n## Acceptance commands as executed by the supervisor before this review`n`n$acceptanceReport" })
$(if ($st.repairHint) { "`n## Instructions from the repair step (follow them exactly; they override your own reading of the findings)`n`n$($st.repairHint)`n" })
"@
    $prompt = Fill-Template (Get-TaskRole $Issue.body) @{ ISSUE_NUMBER = $n; REPOSITORY = $Repository; BRANCH = $branch; ISSUE_BODY = [string]$Issue.body; REVISION_SECTION = $revision; LESSONS = (Get-LessonsSection); AGENT_COMMON = (Get-AgentCommonSection) }
    $launchOptions = @{}
    $timeout = $ImplementTimeoutMinutes
    if ($expert) {
        $launchOptions.ExpertSession = $true
        $launchOptions.ExpertModel = [string]$st.pendingRevision.model
        $reasoning = 'medium'; $timeout = $ExpertTimeoutMinutes
        $prompt += "`n`n" + (Get-Content -LiteralPath (Join-Path $promptDir 'expert-recovery.md') -Raw -Encoding utf8)
    }
    $run = Invoke-Agent -Provider $author -Mode edit -Prompt $prompt -WorkDir $worktree -Tag "issue-$n-revise-$round" -TimeoutMinutes $timeout -ExtraWritableDirs @((Git-Common-Dir $worktree)) -CodexReasoning $reasoning @launchOptions
    if ($run.QuotaBlocked) {
        Register-QuotaBlock $Issue $author $run "revision"
        # The revision never started: nothing is owed to the pull request and this round did not
        # happen. Roll the state back to exactly what it was before the round so the task resumes
        # cleanly once the provider is back, rather than leaving a push owed that does not exist.
        # awaitingRevisionBy deliberately stays set (the author still owes this revision, and the
        # main loop must keep waiting for THAT provider), and the interruption is recorded so the
        # "no progress at the same commit" rule above does not fire on a revision that never ran.
        # Whatever the author already edited before the quota hit stays in the worktree; the next
        # revision session builds on it.
        $st.pendingPush = $false
        $st.revisions = $round - 1
        $st.totalRevisionAttempts = [int]$st.totalRevisionAttempts - 1
        if ($expert) { $st.expertAttempts = [int]$st.expertAttempts - 1 }
        $st.revisionInterruptedByQuota = $true
        Save-State $n $st | Out-Null
        return
    }
    # A revision session really ran from here on, so the next unchanged commit is the author's.
    $st.revisionInterruptedByQuota = $false
    if ($run.Unsafe) { Report-Failure $Issue "``$author``'s revision worker ownership could not be durably confirmed, so its outcome cannot be trusted; not validating or pushing the revision"; return }
    if ($expert -and -not $run.Ok -and -not $run.TimedOut) { Report-Failure $Issue "Expert session failed (exit $($run.Exit)); no automatic model fallback. Inspect its preserved output before retrying. Commits and push recovery remain recorded."; return }
    if ($run.TimedOut) { Write-Log "Issue #${n}: ``$author`` did not finish revision $round within $timeout minutes; pushing whatever it committed and letting the checks and the reviewer judge it" }
    # The repair hint is for one revision only; the next round is judged on its own.
    if ($st.repairHint) { $st.repairHint = $null; Save-State $n $st | Out-Null }

    $midRevision = Get-Issue $n
    if (-not $midRevision) { Write-Log "Issue #${n}: could not re-check issue state after the revision ran (gh unreachable); deferring to the next cycle"; return }
    if ($midRevision.state -ne "OPEN") { Write-Log "Issue #$n was closed while ``$author`` was revising it; discarding the revision instead of pushing it"; return }

    $problem = Validate-And-Push $Issue $worktree $branch $author
    if ($problem) { Report-Failure $Issue "revision $round could not be pushed: $problem"; return }
    $st.pendingPush = $false; $st.awaitingRevisionBy = $null; $st.pendingRevision = $null; Save-State $n $st
    Comment $n "Supervisor: revision $round pushed. Back to review."
}
