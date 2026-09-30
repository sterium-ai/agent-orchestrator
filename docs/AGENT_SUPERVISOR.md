# Supervisor reference

> **In short:** the complete description of how the supervisor behaves: how it moves work
> through its stages, what it checks, how it recovers from failures, and why each rule exists.

## What it is

`scripts/agent-supervisor.ps1` is a CLI-to-CLI orchestrator that uses GitHub issues as the
durable queue and audit trail. It runs on an always-on Windows host as a scheduled task
(`scripts/install-supervisor-task.ps1`), from the main clone of the target repository. Task
state survives a crash because it lives in GitHub labels, comments and pull requests, not in a
terminal.

The product owner only files `objective` issues; see `docs/HOW_TO_GIVE_OBJECTIVES.md`.
Configuration (repository, test gate, trusted authors, models, ownership rules) is described in
the README; this document explains the behaviour.

Where a rule exists because of a specific failure, the failure is described briefly; the
incidents come from the project in [the case study](case-study.md).

## Pipeline

```text
objective ──planner (read-only)──► task issues ──► agent-ready / agent-blocked
agent-ready ──implementer (edit, isolated worktree)──► validate ──► push ──► draft PR ──► agent-review
agent-review ──reviewer = the OTHER provider (read-only)──► approve ──► squash-merge ──► agent-done
                                                        └─► request_changes ──► author revises (up to -MaxRevisions, default 6) ──► agent-review
anything unresolved ──► agent-failed (+ comment on the objective)
```

Each poll cycle does at most one unit of work, in priority order: stranded
`agent-in-progress` issues (see "Recovering from an interruption mid-task" below), then
pending reviews, then unplanned objectives, then ready tasks. One agent runs at a time;
parallel workers can be added later by giving each its own worktree root and lock.

## Lessons loop

The supervisor turns a reviewer finding that keeps recurring into a durable rule instead of
letting the same mistake cost another review round. `scripts/lessons.ps1` is the pure
reader/writer/matcher; `docs/agent-prompts/lessons.md` and `.agent-state/findings.jsonl` are the
two files it operates on. The loop, run from inside `Invoke-Review`:

- **record** — every reviewer verdict's **blocking** findings are appended, one per line, to
  `findings.jsonl` (`Add-Finding`). Minor findings never become lessons: a nit phrased alike
  twice must not turn into a "hard rule" reviewers are then told to enforce.
- **match** — `Get-FindingMatches`/`Test-RuleSimilarity` compares a new finding's `rule` text
  against prior findings **from other tasks** (a finding restated in a later round of the same
  task is unresolved, not repeated). Word overlap after a stop-word list, plus a small
  same-file/same-verb boost (no file boost for `agent-supervisor.ps1`/`run-agent.ps1`, which
  nearly every finding names); threshold 0.65.
- **learn** — `Add-Or-BumpLesson`: the first repeat of a finding creates a new `Active` entry in
  `lessons.md` (`New-LessonId`); a further match against an existing `Active` entry bumps its
  `hits`/`last-seen` instead of duplicating it; a match against a `Retired` entry stays retired.
  A changed `lessons.md` is committed and pushed straight to `main` from the review step. If
  the push cannot be made (checkout behind `origin/main`, network), the local commit and file
  change are discarded and logged, so the main checkout never diverges from `origin/main`
  (a diverged checkout makes `Update-Self`'s ff-only pull fail silently forever).
- **inject** — `Build-LessonsSection` renders the current `Active` entries (dropping the
  fewest-hit, oldest ones first once over `-MaxEntries`/`-MaxChars`; entries marked
  `pinned: true`, i.e. the curated seeds, are never dropped) into the planner,
  implementer and reviewer prompts, so every new task starts with the accumulated rules already
  in view.
- **check** — before a review round is spent, `Get-LessonCheckFailures` runs each `Active`
  lesson's optional `check` regex against the input its `check-on` field names: the task's
  acceptance-commands block (`acceptance`) or the lines the diff adds to test files
  (`test-additions`); a check without `check-on` is inert. A match fails the task mechanically,
  the same way `Get-MechanicalFailures` does, without asking a reviewer. A match on the
  acceptance block (L-001) is tagged `(task-body)` and goes to the owner, since the author cannot
  edit the issue text.
- **retire** — moving an entry from `## Active` to `## Retired` in `lessons.md` is a manual
  edit, done once the underlying mistake is generalized into the prompts/rules themselves or no
  longer applies. A retired rule is not deleted: a future finding that still matches it is
  recognised and left alone instead of reopened as a new lesson.

### File formats

`docs/agent-prompts/lessons.md` — two sections, `## Active` and `## Retired`, each holding
`### L-<NNN> (<date>)` entries with fields `rule`, `do`, `source`, an optional `check` (a regex,
backtick-quoted) with its `check-on` target, `hits`, `last-seen`, and an optional `pinned`. Read
and written by `Read-Lessons`/`Write-Lessons`. The file ships with eight curated lessons (six seed rules and two capability rules);
the supervisor reads the target repository's copy (`lessonsFile`, default
`docs/agent-prompts/lessons.md`) and falls back to the seed until the first lesson is learned
there.

`.agent-state/findings.jsonl` — append-only, one compact JSON object per line:
`{task, pr, round, reviewer, file, issue, rule, date}`. Written by `Add-Finding`; read back as
`PriorFindings` for the match step above.

## Provider policy

- Planner: `-PlannerProvider` (default `claude`), read-only, in a detached worktree of
  `origin/main`.
- Implementer: the provider named in the task issue (`Provider:` line), chosen by the
  planner. Claude Code runs `-p --permission-mode acceptEdits` with an allow-list limited to
  file tools, read-only git, `git add/commit` and the configured `agents.shellCommands`
  (default `python`, `py`, `powershell`). Codex runs
  `codex exec --sandbox workspace-write` with the shared `.git` directory added as a
  writable dir (`--add-dir`) so commits work from a worktree. The interactive-`codex`
  auto-approval convenience flag does not apply to `codex exec` and is never passed;
  `codex exec` is already non-interactive, and the `--sandbox` flag is what controls what it
  may write.
- Reviewer: always a *different* provider from the author (`Reviewer:` line, defaulting to
  the author's partner), read-only: Claude with read/grep/glob and read-only git only; Codex
  with `--sandbox read-only`; Copilot with only read-only git allowed and `write` denied.
- Third provider: GitHub Copilot CLI (`copilot`, `npm install -g
  @github/copilot`, authenticated with the GitHub account). It is the stand-in seat, not a
  planner default: `Get-EffectiveReviewer` asks it to review whenever the assigned reviewer
  is out of quota (immediately, since a review is one read-only session), and
  `Get-EffectiveAuthor` hands it an implementation when the assigned author has been out for
  longer than `-SwapAfterMinutes` (the hand-over is written into the issue body and the
  original author becomes the reviewer). Without a third provider, one exhausted allowance
  stalls every review until that provider resets, which can take days. A task may also name
  `copilot` explicitly. `run-agent.ps1` drives it with the prompt on stdin,
  `-s` (reply only), `--no-ask-user` (a tool that is not pre-allowed is silently denied, never
  prompted for), `--disable-builtin-mcps` (no GitHub API from inside the sandbox), an
  allow-list mirroring Claude's, and `--usage-output-file` so real token and premium-request
  usage lands next to the session output for the dashboard. `-CopilotModel` (default `auto`)
  picks the model; `auto` rejects a reasoning-effort setting, a named model gets the task's
  codex effort level. If `copilot` is not on PATH the supervisor logs it once and runs with
  two providers exactly as before.
- Several logins per provider (Codex only): a usage limit belongs to
  a login, not to the vendor, so `providers.json` cooldowns are keyed per *account*. The
  primary login is the bare provider name (`codex`, the default `~/.codex`); every subfolder
  of `-CodexAccountsDir` (default `%USERPROFILE%\.codex-accounts`) that holds an `auth.json`
  is a reserve login `codex/<folder>`, created by the owner once with
  `$env:CODEX_HOME="$env:USERPROFILE\.codex-accounts\<folder>"; codex login`. Accounts are
  used in order (primary, then reserves alphabetically): `Invoke-Agent` picks the first login
  not on cooldown and passes its folder to `run-agent.ps1 -CodexHome`, which sets
  `CODEX_HOME` for that one `codex exec`. When a login hits its wall, `Register-QuotaBlock`
  rests only that key; the provider is still "ready" while any login is, so the very same
  task is re-run with the next login on the next cycle (an implementation from scratch, a
  revision through the usual `awaitingRevisionBy` path) instead of waiting for the reset or
  being handed to another vendor. Only when every login is out does the provider rest, until
  the earliest reset among them. Two logins of one vendor are still one provider for the
  reviewer rule: a reserve never reviews its own vendor's work. The dashboard shows one block
  per login (state and quota bars read from that `CODEX_HOME`'s session transcripts) and
  `status.json` says which login is in use.
- Every agent run is a child process with a timeout (`-PlannerTimeoutMinutes`,
  `-ImplementTimeoutMinutes`, `-ReviewTimeoutMinutes`); on timeout the whole process tree
  is killed and the task is marked failed.

Prompts are templates in `docs/agent-prompts/` (`planner.md`, `implementer.md`,
`reviewer.md`). Planner and reviewer must answer with a single JSON object; the supervisor
parses it and refuses to act on anything else.

## Task role

Every task issue carries an optional `Role:` field, read by `Get-TaskRole`
(`scripts/lib/role-select.ps1`) the same way `Provider:`/`Reviewer:` are read. A role selects the
author prompt `<role>.md` in the prompt templates directory, so a project can add specialised
author prompts (a documentation writer, a data migrator) without code changes. A missing field,
a role with no prompt file, a reserved name (`planner`, `reviewer`, `repairer`, `lessons`,
`expert-recovery`) or anything that is not a plain name falls back to `implementer.md`.
`docs/agent-prompts/_agent-common.md` holds the rules every author role shares verbatim --
owned-paths discipline, commit style, the `## Blocked` handoff shape, and the mandatory
`HANDOFF.md` contents -- injected into each template through `{{AGENT_COMMON}}`
(`Get-AgentCommonSection`), so the prompts cannot drift apart on those rules.

## Validation gate before a PR is opened or a revision is pushed

1. Uncommitted work is committed on the agent's behalf (so a sandbox that could not run
   `git commit` does not lose the work).
2. At least one commit ahead of `origin/main`.
3. Generated files the task does not own (`ownership.generatedFiles`) are restored to the
   branch base first (see below).
4. The optional `prePushCommand` runs in the worktree (code generators, an import step that
   writes metadata files) and whatever it produces is committed. Tests are **not** run here:
   the test gate runs in `Get-MechanicalFailures` before every review, so a red test goes back
   to the author as a revision with the real output instead of failing the task with nothing
   to resume from.

Whitespace errors and protected paths are reported before review, as a revision (see
"Mechanical checks" below).

A task failed by the supervisor tells the owner which label resumes it: `agent-review` when an
open pull request exists (commits kept, checks re-run), `agent-ready` otherwise (the branch is
rebuilt and the implementation redone).

## Self-repair: when a task stops, the pipeline decides before a person does

Every stall that is not a host or safety problem goes through `Invoke-Repair` first (prompt: `docs/agent-prompts/repairer.md`):
the planner provider reads the failure, the task, the objective, the author's handoff, the
last review and the executed acceptance transcript, read-only in the task's worktree, and
returns one decision:

- `hint` — the code is close and the task is fine: the next revision prompt carries exact
  instructions (file, function, lines, what "done" looks like), one round only. The normal
  answer when a test fails the same way twice; it keeps all the work done.
- `patch-task` — one or a few lines of the task are wrong (a criterion an ADR forbids, an
  impossible command, a wrong path): exact find/replace pairs, each matching once, applied to
  the issue body.
- `rescope` — the change needs files the task does not own; they are added under
  `## Owned paths`.
- `capability` — the author said it cannot do something. The repair step establishes WHAT it
  cannot do and WHY (handoff plus the session's stdout/stderr), and records a pinned, permanent
  rule in `lessons.md` (`Add-CapabilityLesson`) with the workaround that does work from inside
  the sandbox; the current task continues with that workaround as its hint. Only when nothing
  works from the sandbox does it stop for the person, with the one exact thing to do on the host.
- `rewrite-task` — large parts of the task are wrong; the body is replaced (validated first).
  Last resort before `human`: it discards the least work but costs the most rounds.
- `switch-author` — the author followed a correct hint and the check still fails, or keeps
  drifting: the task is handed to the other provider (`new_author`, normally `claude` as the
  stronger model) with the branch and commits kept; the previous author becomes the reviewer.
  Does not spend the repair budget; at most once per task.
- `human` — a product decision is needed. Only this (and a host action) ends in `agent-failed`,
  with the repair step's plain-language explanation.

### Let the agents run the tests

Authors, reviewers and the repair step are allowed to run the project's own test tools
(`agents.shellCommands`); the supervisor's host run stays the authoritative result. Without
this, one task spent five revisions and two repair diagnoses reasoning about a red test nobody
was allowed to run; the real cause was visible in the first line of its output. If a tool writes outside the
worktree (a user-data folder, a cache), list that folder in `agents.sandboxWritableDirectories`
so Codex's sandbox does not deny it and fail the test for the wrong reason.

After an applied decision the round counters reset and the task returns to `agent-review`
(or `agent-ready` when no pull request exists). `-MaxRepairs` (default 2) bounds how many
times this can happen per task; past it, a person is asked.

Stalls routed through the repair step: a `## Blocked` handoff; a pre-review failure of the
environment/task-body class (a nested `powershell -Command` acceptance line is first repaired
deterministically by `Repair-NestedAcceptanceCommands`, no model involved); the same check
failing twice in a row; a revision that committed nothing after a rejection; the revision
ceiling; a `task-body:` finding; the same finding restated three rounds; a revision or
implementation that could not be published. A rebase conflict on an approved branch is not a
stall at all: the author merges `origin/main` in its worktree (`conflictPending`) and the
result gets a fresh review. A worker that runs out of time has whatever it committed published
and judged, instead of being discarded; an implementation that produced no commits is retried
once with the other provider.

What still ends in `agent-failed` without a repair attempt: a worker whose ownership cannot be
confirmed, a corrupted state file, a reviewer that twice returns no verdict, a pull request or
merge that GitHub refuses. Those are the cases where guessing could lose work.

A `## Blocked` report with reason `out-of-scope` or `task-body` that names the files it needs
is handled without the repair step at all: `Get-PathsNamedInBlockedReport`
(`scripts/lib/task-preflight.ps1`) extracts the repo-relative paths from the report, keeps those
that exist in the worktree and are not already covered by an owned entry (never a protected
path from `ownership.protectedPaths` or the supervisor's own scripts), `## Owned paths` is widened
with `(auto: named in the author's ## Blocked report)` markers, and the author is sent straight
back with a pending revision that quotes its own report. It counts as one of the task's three
free rescopes and spends neither a repair session nor a review round; when no usable path is
named, or the free rescopes are used up, the repair step runs as usual.

The same rescope applies to a reviewer's `task-body:` findings when every such finding only
names files the task does not own ("needs file outside owned paths: X"): the files are added
with `(auto: named in a reviewer's task-body finding)` and the whole review goes to the author as
a revision, without the repair step. A finding that also disputes an ADR or a contract is a
judgement call and still goes to the repair step (a reviewer must not override an accepted
design by naming a file). A repair session that returns no parseable decision is retried once
in the same attempt before the task is handed to a person; `Extract-Json` also tolerates
trailing commas, a common model slip that a strict JSON parser rejects.

A free rescope never grants a path the task's own text forbids: every path named in a
`Do not modify / change / edit / touch ...` sentence (`Get-ForbiddenPathsFromBody`). A
`## Blocked` report or reviewer finding that names such a path is a scope decision and goes to
the repair step (which may hand it to a person) instead of widening the task. A whole top-level
folder (`src/`, `tests/`) is never granted either; a deeper subfolder still is. Without this
rule, a task whose non-goals forbade core changes was widened onto two core files by two free
rescopes, patched the core scheduler, and was then rejected for it.

Before the supervisor commits work an author left uncommitted (`Validate-And-Push`), it
restores every generated file the task does not own -- paths matching
`ownership.generatedFiles` that changed against the branch's merge base with `origin/main` and
existed there -- back to that base and commits the restore on its own
(`Restore-UnownedGeneratedFiles`, filter `Select-UnownedGeneratedPaths` in
`scripts/lib/owned-paths-auto.ps1`). In the case-study project an engine's import step, run by
a required acceptance command, rewrote a resource file's internal ids non-deterministically;
committing that churn made the reviewer block the diff for an unowned file no author could
revert (the corresponding lesson was hit 22 times). New generated files are left alone. The
issue gets one comment naming the restored files.

A capability lesson (`Add-CapabilityLesson`) is recorded only when it is a general, author-side
rule: a workaround of "none", or a narrative that names commits or runs past 400 characters, is
logged and dropped instead of becoming a pinned rule.

A task that fails (`Report-Failure`) is put on the owner's dashboard immediately
(`Register-FailureOnDashboard`): the cached queue is patched and re-exported, and the label
cache is marked stale, instead of waiting for the next throttled refetch -- which, during a
review cycle that runs for hours, could be hours away.

`add_owned_paths` in a repair decision is applied whatever the main decision (`patch-task`,
`rewrite-task`, `hint` as well as `rescope`): the repair model lists every file it authorises
there. If only `rescope` read the list, a `patch-task` that also named five files would land
only its patches, the author would stop with `## Blocked` on exactly those files, and the
repair budget would be gone. Files already covered by an owned entry are skipped; the
added bullets carry `(auto: authorised by the repair step with its <decision>)`.

## Task-body findings from the reviewer

A blocking finding whose `fix` starts with `task-body:` means the reviewer judged the task
text itself defective (an acceptance criterion an accepted ADR forbids, or one that cannot be
met as written). It goes to the repair step (above), which normally rewrites the task text itself; no
revision is spent.

## Non-convergence on reviewer findings

Tasks whose owned paths include `scripts/agent-supervisor.ps1` or `scripts/run-agent.ps1` get
a ceiling of 3 rounds instead of `-MaxRevisions`.

Besides the round ceiling (`-MaxRevisions`), an individual blocking finding that persists for
three reviews triggers the bounded repair diagnosis (`Test-RuleSimilarity`, threshold 0.6),
even if other findings change. Similarity triggers diagnosis, never approval. A successful
rescope, hint, task patch or rewrite with an existing PR records `pendingRevision` and sends
the evidence directly to the author. After correction and push, independent review is required.

`-MaxTotalRevisions` (default 12) also caps cumulative correction attempts per issue across
repairs and rebuilt branches. Quota refusals do not consume this budget. Legacy issue state
initializes `totalRevisionAttempts` from correction launches in the log, excluding quota
refusals, with the existing round counter as a lower bound. Reaching this ceiling reports a
failure and preserves commits for diagnosis or task splitting; relabelling alone does not
reset the budget. See ADR 002 (`docs/decisions/002-workflow-reliability.md`) for compatibility and rollout.

### Bounded expert correction

With `-ExpertRecoveryEnabled $true` (the default), a finding repeated across
three reviews, the revision ceiling, or exhaustion of the repair budget queues one expert
correction on the existing task worktree. A preflight failure without a worktree never starts
an expert in the supervisor checkout. This is driven by failed progress, not elapsed time or
quota exhaustion.

Claude-authored tasks use `models.claudeExpert` (default `claude-fable-5-1`); Codex-authored
tasks use `models.codexExpert` (default `gpt-6-astra`); an empty value means the CLI's default
model. Copilot tasks explicitly transfer to Codex with Claude as reviewer before any expert writes.
Both use medium effort and `-ExpertTimeoutMinutes` (default 45). The runner's `-ExpertSession`
enables full CLI permissions for this exceptional writer only; ordinary authors and reviewers
retain their existing policies. Full access is host-wide, not a technical worktree sandbox:
the expert prompt limits the task, forbids live-supervisor changes, unrelated credentials and
remote publication, and all existing ownership, acceptance, review and merge gates still run.

`pendingRevision` retains expert/model/provider intent across quota waits. `expertAttempts`
is persisted before launch and is never reset by task repair or rebuilt branches. One expert
may run after the normal cumulative ceiling, giving an upper bound of `MaxTotalRevisions + 1`
correction sessions; a quota refusal refunds both counters. A failed model invocation does not
silently switch models or start a second expert. As with ordinary revisions, interrupted work
uses the existing worker-ownership and pending-push recovery; it never implies approval.

The expert receives the current task, objective, existing handoff, latest three reviews,
acceptance evidence and repair hint, with paths to the full evidence. It diagnoses and fixes
the cause, records reproduction and regression results, and returns to independent review.
Provider login/quota checks do not guarantee access to a particular model; inspect the saved
session error if a subscription rejects it. Disable future escalation with
`-ExpertRecoveryEnabled $false` after any active session finishes. Queued expert intent is
preserved but its launch is blocked while disabled; do not erase it manually. See ADR 003
(`docs/decisions/003-bounded-expert-recovery.md`). The permission-bypass flags make this the
riskiest session the pipeline runs; see "Security model" in the README.

## Merge

On approval the branch is rebased onto `origin/main` if behind (a conflict marks the task
failed rather than guessing). The reviewer read the local worktree, not the PR diff, so
before merging the supervisor re-fetches the PR and compares its `headRefOid` to the
worktree's own `HEAD`; a mismatch (stale or not-yet-pushed revision — see "Recovering a
revision that finished but was not confirmed pushed" below) defers the merge to the next
cycle instead of merging whatever the remote branch happens to contain. Once they match,
the PR is marked ready and squash-merged, the issue is closed, the worktree and branch are
deleted, dependants whose blockers are all closed move to `agent-ready`, and the objective
is closed with a **Done** comment when all its tasks are closed.

## Recovering from an interruption mid-task

All durable state is GitHub labels, so a scheduled-task restart (host reboot, crash, manual
stop) never loses track of a task: it just leaves it labelled `agent-in-progress` if the
restart happened after `Invoke-Implementation` set that label but before the later move to
`agent-review`.

Three rules keep interrupted work from being lost or repeated:

- **Salvage before cleanup.** If the interrupted worktree holds work (commits ahead of
  `origin/main`, or edits the agent never committed), recovery runs it through the normal
  `Validate-And-Push` gate and, if it passes, publishes it to review (`Publish-Implementation`,
  the same tail a normal run uses) instead of deleting it and paying for a second
  implementation. This also covers a transient `gh` failure right after the agent finished,
  which would otherwise defer "to the next cycle" and then discard the finished worktree. Work
  that fails the gate is parked on a local branch `abandoned/issue-<n>-<timestamp>` (never
  pushed) before the task is redone.
- **Deadlines survive restarts.** `Invoke-Agent` records each worker's deadline in its
  `worker.json`; `Get-LiveWorkerForIssue` stops a surviving worker from a previous supervisor
  once that deadline has passed, instead of waiting on it indefinitely because the process
  that held the timer died.
- **A quota pause is not a failed revision.** When the author's quota runs out at the start
  of a revision, the issue state keeps `awaitingRevisionBy = <author>` and the main loop
  gates that issue on the *author* being usable, not on a reviewer; and the "pre-review checks
  failed again at the same commit" rule is suppressed for a revision that never ran
  (`revisionInterruptedByQuota`). Without this, a task paused on quota was failed seconds
  later and reimplemented from scratch.

At the start of every poll cycle, before objectives, reviews or ready tasks, the supervisor
queries issues labelled `agent-in-progress`. The **supervisor process** side of this is
unambiguous: the startup lock (below) guarantees at most one supervisor process is ever
running, and the loop is single-threaded, so a live supervisor holding this label is always
blocked inside the `Invoke-Implementation` call that set it and cannot simultaneously be
polling its own issue — every hit here is a supervisor that stopped or restarted.

That does **not** automatically mean the *worker* is dead. `Invoke-Agent` launches the actual
CLI (claude/codex, via `run-agent.ps1`) as an independent process the supervisor merely waits
on with `WaitForExit`; if the supervisor died mid-wait, that worker can still be alive and
writing to the worktree.

### Durable worker ownership: a launch-intent record, written before the process exists

`Invoke-Agent` persists `<tag>.worker.json` in two steps, both **before** `WaitForExit` is ever
called:

1. **Launch intent**, written *before* `Start-Process` runs at all: `{ pid: 0, startTime: 0 }`.
   This is the record's very first write, so a crash at any point from here on — including
   before the child process exists — always leaves *some* record behind for recovery to find.
2. **Confirmed identity**, overwriting the same file immediately after `Start-Process` returns:
   `{ pid: <real pid>, startTime: <real start ticks> }`.

Readers (`Get-LiveWorkerForIssue`, and `Invoke-Recovery`'s own check) treat `pid <= 0` as
"a launch was attempted but its outcome is unknown" — never as "confirmed dead" and never as
"safe to reclaim". `Get-LiveWorkerForIssue` returns this as a distinct `Confirmed = $false`
result (as opposed to `Confirmed = $true` for a positively-identified live process), and every
caller — `Invoke-Recovery`'s own check, and the two `Get-LiveWorkerForIssue` call sites in
`Invoke-Implementation` and `Invoke-Review` — marks the issue `agent-failed` for manual
attention on `Confirmed = $false` rather than either reclaiming the worktree or silently
skipping the same unconfirmed record forever with no path to resolution. Once a
real pid is on file, recovery confirms liveness by matching both `pid` and `startTime` against
the live process table (so a recycled PID from an unrelated process is not mistaken for the
worker), and if it is still alive, force-kills its process tree (`taskkill /T /F`) and
**re-checks** that the whole tree actually stopped before removing the record or touching the
worktree: `Get-ProcessTreeIds` snapshots every live descendant of the launched PID (walking
`Win32_Process` parent links) *before* `taskkill` runs, and `Confirm-ProcessTerminated`
re-checks every one of those PIDs afterwards, not just the original one — so a `taskkill` that
kills the `powershell.exe` wrapper but leaves a `claude`/`codex` CLI descendant running is not
mistaken for a clean stop. Any surviving member of that tree (or a `taskkill` that does not
stick at all) also marks the task `agent-failed` instead of proceeding. Only after the whole
tree is known to be gone (or never existed) does recovery clean up the worktree/branch and move
the issue back to `agent-ready`. The branch name is deterministic (`agent/issue-<n>-<slug>`), so
redoing the work safely force-pushes over the same branch and an existing PR (if any) just
receives the new commits; `Invoke-Implementation`'s "PR already exists" handling takes it from
there.

If writing either half of the worker record fails outright — most likely a disk or permissions
problem — `Invoke-Agent` treats that as fatal for the run: it stops the process it just started
(confirming the kill the same way as above) and returns a result flagged `Unsafe`. Callers
(`Invoke-Implementation`, and the revision branch of `Invoke-Review`) check this flag *before*
`Validate-And-Push` and skip straight to `agent-failed` if it is set, so a worker whose identity
could not be durably recorded never gets its worktree committed, pushed, or merged on the
strength of an exit code alone.

If the record file itself is simply missing at the top of `Invoke-Recovery` — not "confirmed
dead", just absent — that can only mean the supervisor crashed before `Invoke-Agent`'s own
first write (e.g. mid worktree-creation, before the agent process was ever launched), since the
write happens before `Start-Process`. Recovery still corroborates with the worktree's own
activity in that case, as a second line of defense: it looks at the most recently modified file
under the worktree and, if that is more recent than a quiet-period threshold (the larger of 300
seconds or twice `-PollSeconds`), defers recovery again rather than touching something that
might still be being written to. Only once the worktree has been quiet for that long does it
proceed.

**Known limitation:** a sliver of the original gap cannot be closed with PID/StartTime tracking
alone — a crash in the literal instant between the launch-intent write and `Start-Process`
actually creating the process, or between `Start-Process` returning and the pid-confirmation
write, is indistinguishable from "nothing was launched yet". This is exactly why readers treat
`pid <= 0` as unconfirmed rather than dead: the residual window fails closed (a human has to look)
instead of silently reclaiming a worktree a real process might still own. Closing it completely
would require OS-level process tracking (e.g. a Job Object) beyond what these scripts use today.

### Mid-revision and mid-review worker liveness

The `agent-in-progress` recovery path above only ever runs for the label `Invoke-Implementation`
sets. A revision (`Invoke-Review`'s "request_changes" branch, which re-launches the implementer
against the same worktree) and the review agent itself both run while the issue stays labelled
`agent-review`, so a supervisor restart mid-revision or mid-review is invisible to that path.
`Invoke-Review` closes this gap directly: before touching the worktree or launching any agent,
it calls the same worker-record check (`Get-LiveWorkerForIssue`) against every worker tag ever
used for that issue number (`issue-<n>-implement`, `issue-<n>-revise-<round>`,
`issue-<n>-review-<round>`). If any of them is still alive, the cycle skips that issue entirely
— no new reviewer, no new revision, no worktree read — until the stray process exits on its own,
at which point the stale record is dropped automatically and normal review resumes.

### Recovering a revision that finished but was not confirmed pushed

Once a revision agent exits, its changes exist only in the local worktree; the remote PR still
shows the code from the round that was just rejected until `Validate-And-Push` actually lands
the new commits. A revision can be interrupted at any point — while the worker is still running,
right after it exits, or during the re-check/push that follows — and a naive retry would then
launch a fresh review against the (updated) local worktree while the remote PR still holds the
older, rejected code; an approval would merge that stale remote code instead of what was
actually reviewed, or the pre-merge `headRefOid` mismatch check would simply defer forever,
since nothing would ever push the local commits.

To prevent this, the supervisor persists a `pendingPush` flag in the issue's local state
**before the revision worker is even launched** — not after it returns. This matters: otherwise a crash
while the revision agent is still writing to the worktree, or right after it exits, would
leave no trace that a push was owed. The flag is on disk for the entire lifetime of the revision, so every subsequent `Invoke-Review` call for that
issue sees it. The check order inside `Invoke-Review` is deliberate: the live-worker check
(`Get-LiveWorkerForIssue`, covering the `issue-<n>-revise-<round>` tag) always runs *before* the
`pendingPush` check, so a revision worker that is still alive is never mistaken for "finished,
just needs pushing" — the cycle skips entirely until the worker is confirmed gone. Only once
that is true does the `pendingPush` branch retry `Validate-And-Push` (instead of running a new
review round) before doing anything else. This is the second, narrower half of what the
`headRefOid` check under "Merge" guards more generally, and `Invoke-Implementation` clears a
stale `pendingPush` flag whenever a task is fully redone from scratch (a fresh worktree/branch
makes any older flag meaningless).

`pendingRevision` records a correction owed before launch, including across author quota
waits. `pendingPush` records a launch whose commits still need publishing. Recovery checks
live workers first, then pushes owed commits, then dispatches an unstarted correction. A fresh
branch clears both transient flags and finding streaks but preserves `totalRevisionAttempts`.

### Exclusive startup lock

With a check-then-write lock, two supervisors starting at the same instant could both pass
a "does the lock file exist?" check before either wrote it, defeating the single-instance
assumption the recovery logic above depends on. The lock is therefore an OS-level exclusive file
handle (`FileStream` opened with `FileShare.None`) held for the process's entire lifetime: a
second process's attempt to open the same file fails immediately, and a crashed process's
handle is released by Windows when the process exits, so no separate staleness/PID check is
needed.

### A restart must be able to come back: leaked descendants are swept

The scheduled task runs `supervisor-loop.cmd`, which relaunches the supervisor whenever it
exits (a self-update exit, a crash) and sends its stdout/stderr to `.agent-state/task-stdout.txt`
and `task-stderr.txt`. cmd.exe opens those files with a share mode that admits no second writer,
and every process the supervisor starts with inherited handles -- the agent worker and, through
it, the agent's shells, test tools and tails -- receives a copy of them. A descendant that
outlives its run therefore keeps the files locked, and the wrapper's next `>> task-stdout.txt`
fails: the supervisor is never relaunched, nothing is logged, and the pipeline silently stops.
In the case-study project that once cost an hour right after a merge: an agent had left four
`sh -c "<engine> --headless ... | tail"` chains behind (the engine never quit; the agent's shell
was the only thing it could kill), and a task already pushed for its second review round simply
waited.

Three layers prevent this.

- The supervisor sweeps **leaked log-file holders** with the Windows Restart Manager
  (`Get-FileHolders` / `Stop-LeakedLogHolders`): it asks the OS exactly which processes hold its
  own stdout/stderr files (and the canonical `task-*.txt` names) open and kills every one that is
  neither itself, one of its ancestors (the wrapper legitimately holds them), nor part of a live,
  recorded agent worker's process tree. No name or parent heuristics; a PID is only killed if its
  start time matches what the Restart Manager reported. The sweep runs at startup, after each
  agent run returns (so a leak dies minutes old, not hours), and right before a self-update exit.
- `Stop-OrphanedProcesses` judges a configured tool process (`orphanSweep.processNames`,
  optionally filtered by `orphanSweep.commandLineContains`, e.g. `--headless`) orphaned on its
  **whole launcher chain** (`Test-OrphanChain`): it climbs through shell/launcher links (sh, bash,
  cmd, powershell, node, python, the configured tool names...) and treats a missing link, or a
  "parent" younger than its child (a recycled PID), as a broken chain. It stops without a verdict
  at the first non-launcher process, so a copy the owner started from a terminal or an editor is
  never touched. With no names configured the sweep does nothing.
- The wrapper written by `install-supervisor-task.ps1` probes the canonical log names each turn
  and falls back to `task-stdout.<n>.txt` / `task-stderr.<n>.txt` when one is still locked, so the
  relaunch itself no longer depends on the sweep having run. The supervisor deletes rotated files
  older than a week. A wrapper that is already running keeps executing the file it started with,
  so the new template only takes effect after the installer is run again (which restarts the
  task; do it while the supervisor is idle).

A dry run never kills anything.

## Mid-flight issue closure

A human can close a task issue at any time, including while a long-running agent call
(implementer, reviewer, or a revision) is in progress. Both `Invoke-Implementation` and
`Invoke-Review` check the issue is still open before doing anything (worktree/branch/PR
creation, or review/merge), **and** re-check immediately after every agent call returns and
before the next externally-visible action (pushing, opening/commenting a PR, posting a
review, merging, or sending a revision back for another round). If the issue was closed in the
meantime, the result of that agent call is discarded (worktree/branch cleaned up where one was
created) and nothing is published for it. If the re-check itself fails (GitHub/`gh`
unreachable), the task is deferred to the next cycle rather than guessing either way.

## Failure policy

- Missing CLI: task stays queued, log warns.
- Planner produced no valid plan, or every task in an otherwise-valid plan was malformed, had
  an unresolvable dependency, or failed to create: `objective-failed` with instructions to
  refine (an objective is never left `objective-planned` with zero children — nothing would
  ever poll it again).
- Agent timeout, crash, no commits, push or PR
  failed, rebase conflict, reviewer still rejecting after `MaxRevisions` rounds (or rejecting the
  same commit twice), reviewer produced no verdict twice,
  interrupted mid-task and the partial worktree (or its still-live worker) could not be
  cleaned up safely: `agent-failed` with the reason as a comment; the objective gets one
  escalation comment.
- A task issue closed by a human before, during, or immediately after implementation/review is
  skipped (logged, not failed): no worktree, branch, commits, or pull request are created or
  published against it.
- A planner task whose `depends_on` names a key that was never successfully turned into an
  issue (malformed, or its own `gh issue create` failed) is itself skipped and logged, rather
  than silently created with "Blocked by: none" — independent valid tasks in the same plan
  still get created.
- Retry is always the same: remove `agent-failed`, add `agent-ready`.

### A provider with no quota left is never a task failure

This is deliberately separate from everything above. When a provider CLI refuses because the
account has no allowance left, nothing about the task has been attempted, so nothing about the
task may be concluded. `run-agent.ps1` recognises the wording both CLIs use
(`You've hit your session limit · resets 5:30pm`, `You've hit your usage limit … try again at
7:51 PM`), extracts the reset time they state, and exits **77** — a code that means "the
provider refused on billing grounds", never "the work was bad".

The supervisor then:

- records the cooldown once, centrally, in `.agent-state/providers.json`;
- leaves the task exactly where it was — an implementation goes back to `agent-ready`, a review
  stays `agent-review`, a revision rolls its round back — so no review round, revision round or
  failure counter is consumed;
- comments **once** per reset time on the issue, saying it is paused and when it resumes;
- stops offering that provider any work at all until the stated time, while work that needs the
  other provider continues normally;
- resumes by itself: the cooldown simply expires, with nothing to clear by hand.

The reset time comes from the provider's own message rather than a retry ladder, so the next
attempt happens once, when it can actually succeed, instead of repeatedly against a wall. If a
message ever omits the time, the fallback is a single quiet 30-minute wait.

Two rules keep that message honest. The codex log echoes the whole prompt back, and a task
whose body quotes a limit message as a test fixture once had its "resets 5:30pm" read as
codex's reset time: three pauses of 14–16 hours for limits that actually lasted minutes. So `run-agent.ps1` drops every log line that also appears in the prompt
before classifying, and `Get-QuotaBlock` parses the reset time only from the line that
matched the limit pattern, never from the text as a whole. A stated time up to ten minutes in
the past means "now" (codex reports resets to the minute; a launch at 23:43:13 was told
"try again at 11:43 PM"), not "tomorrow".

### Mechanical checks run before any reviewer is asked

`Get-MechanicalFailures` runs in the worktree before a review round starts: PowerShell 5.1 parse
errors in every changed `.ps1`, `git diff --check`, any change reaching into a protected path
(`ownership.protectedPaths`), file budgets (`ownership.budgetsFile`), and the **test gate**:
the project's own test command (`testGate.command`), run by `Get-TestGateFailures` in a fresh
`powershell -NoProfile` in the worktree under `testGate.timeoutSeconds`, whenever a changed path
matches `testGate.whenChanged` (always, when that is empty). If any check fails, the change goes
straight back to its author with the real output and **no reviewer is called and no review
round is spent** -- these are facts a script settles, not opinions a reviewer needs to form.

Incomplete validation is a failure too: a missing checkout, failed base fetch/diff, a test
command that cannot start, or an exception inside the gate must produce a blocking diagnostic.
None of them may be logged or skipped without returning a failure;
`scripts/tests/test-pre-review-gates.ps1` exercises the real gate functions with controlled
command failures. Host/tool/read failures use the existing environment-repair path rather than a
paid author correction. A red test is an author correction; a test command that never finishes
is killed at the timeout and is the author's too (a test that never exits). Checkout entry and
budget reads must terminate on access errors even under the supervisor's normal `Continue`
policy; an unreadable file cannot silently bypass its budget.

#### Automatic ownership widening

`scripts/lib/owned-paths-auto.ps1` applies deterministic, configurable rules
(`ownership` in the configuration) when the planner creates a task:

1. **Tests that reference an owned path.** Every file in `ownership.testDirectory` matching
   `ownership.testFilter` (non-recursive) whose text contains an owned path -- or one of its
   spellings under `ownership.pathAliases`, e.g. `game/` -> `res://` for a Godot project -- is
   added with `(auto: asserts on <path>)`.
2. **Companions.** For each `{ when, add }` rule, when an owned path matches the regex `when`,
   `add` is owned too, with `(auto: required with <path>)`. Typical use: persistence code
   implies its fixtures folder and its schema file.
3. **File budgets.** When an owned path is capped in `ownership.budgetsFile`, the budgets file
   and `ownership.decisionsDirectory` are added, because raising a cap needs a decision record in
   the same change (otherwise the author stops with `## Blocked` on its first revision).

Existing owned files and parent directories are recognized case-insensitively with slash
normalization (`Test-PathCovered`). Exercised by `scripts/tests/test-owned-paths-auto.ps1`.

#### Task preflight for hand-written tasks

The rules above run at planning time, so a task nobody planned -- a reviewer's follow-up task,
an owner rewrite -- reached its author with the tests its owned files imply missing from
`## Owned paths`. `Invoke-Implementation` therefore runs `Get-TaskPreflightAdditions`
(`scripts/lib/task-preflight.ps1`) against the freshly created worktree, after the contract
preflight and before the author prompt is built, applying the same rules to the body as
written (skipping anything already covered by an owned file or directory). Additions are
appended as `(auto: ...)` bullets with `Set-IssueBody`, the in-memory body is updated so the
author sees them, and one comment says what was added and that no author or review round was
spent. A planner task is already widened, so the preflight is a no-op for it; a body with no
`## Owned paths` section is left alone (that is a task defect for the repair step, not
something to invent). Exercised by `scripts/tests/test-task-preflight.ps1`.

### Same failure twice, failures no author can fix, and the author's own "I cannot"

Three rules stop the pipeline from spending sessions against walls no session can move (an
audit of seven stalled tasks in the case-study project counted well over twenty such sessions):

- **The gate compares failures, not commits.** `Get-FailureSignature` hashes the mechanical /
  acceptance failure text with shas, times, durations and temp names blanked. If a round fails
  with the same signature as the previous one, the task stops and is escalated even though the
  author committed something in between (one task made six cosmetic commits against "port
  already in use"). The older same-commit rule is kept as the trivial case. A revision cut short by quota
  still does not count (`revisionInterruptedByQuota`).
- **Failures the author cannot change go to the owner at once.** `Get-FailureClass` names a
  port already in use, access denied / locked files, a timed-out or unstartable command
  (`environment`), and a command that does not parse, names a missing tool or is one the
  supervisor refuses to run (`task-body`). These fail the task with the class in the comment
  and **no author session is spent**. `agent-blocked` is *not* used for this: that label means
  "waiting on prerequisite tasks" and flips back to `agent-ready` by itself.
- **`## Blocked` in the handoff.** The author can say `reason: environment | task-body |
  out-of-scope` plus one line, and `Get-HandoffBlock` stops the task for a person instead of
  relaunching. It is acted on once per commit (`blockedHandledSha`): after the owner fixes the
  cause and relabels `agent-review`, the still-present section is ignored for that commit. Only
  the section counts: the older one-line `SCOPE-BLOCKED:` form is no longer read, because
  a lesson had authors writing it under `## Known limitations` as bookkeeping for files
  they deliberately left alone, and every such finished task was stopped for a repair round
  that changed nothing. A deliberately untouched file is now
  `left untouched (out of scope): <path> -- <why>` under `## Known limitations`.

Two prompt rules go with them. The implementer's revision section demands, per blocking
finding, a `## Revision response` line `finding -> what changed -> why that resolves the
requirement` (or `disputed: <reason>`) and says what does not count as a fix (a fallback where
the behaviour was requested, a check at the symptom instead of the origin, a special case). The
reviewer's follow-up round verifies those lines and re-reads in full, at HEAD, every file it
named in a previous blocking finding, instead of judging the incremental hunk alone.

### A merge conflict is resolved with a real merge, in a session that may run `git merge`

When an approved branch no longer rebases onto `main`, the author gets a conflict session
whose only job is `git merge origin/main`. `run-agent.ps1 -ConflictSession` adds
`git merge`, `git ls-files`, `git cat-file` and `git checkout --ours/--theirs` to that one
session's tools (no `git fetch`: the supervisor fetched `origin/main` into the worktree
just before its own rebase attempt, so the merge is local -- which also keeps Codex's and
Copilot's no-network sandboxes working). An earlier prompt asked for `git fetch` +
`git merge`, which the tool list forbade; the author "hand-reconstructed" the merge as a
single-parent commit, the reviewer then saw every file `main` had changed as an
out-of-scope change, requested changes, the next approval hit the same rebase conflict, and
the loop cost two author sessions and one review per turn with no exit. The lesson recorded from that
episode (L-007 in the shipped lessons file) tells authors to run a real `git merge` instead.

### The supervisor runs each task's acceptance commands on the host

Agent sandboxes often cannot run the project's tests (a CLI's allow-list lacks the tool, a
read-only sandbox denies the temp writes most tests need), so neither the author nor the
reviewer can reliably observe a real test result. Without host-side execution, a reviewer
correctly refuses to approve unverified work, the author is correctly unable to produce the
evidence, and the task circles until it hits `MaxRevisions` (one task lost all seven of its
rounds this way).

The supervisor itself is unrestricted PowerShell on the host, so it does the running -- which
is also why these commands are the most sensitive input the pipeline has (see "Trusted authors"
below and "Security model" in the README):

- The planner emits `acceptance_commands` per task; the supervisor writes them into the task
  issue under a `## Acceptance commands` heading as a fenced ```` ```powershell ```` block.
  Editing that block in the issue body is how the owner adds or corrects commands
  for an existing task; only the fenced block counts, never comments.
- `Get-AcceptanceCommands` extracts the block; `Invoke-AcceptanceCommands` runs each line in
  a fresh `powershell.exe -NoProfile` in the worktree, with a timeout per command
  (`acceptance.timeoutSeconds`, default 300 s) and
  output captured to `.agent-state/acceptance-<i>.out.txt`/`.err.txt`. Exit code decides:
  `0` passes, anything else fails, timeout is `-2`, refused is `-1`.
- Refused outright, without running: anything that deletes recursively, formats, shuts
  down, edits the registry, pushes, hard-resets or cleans git, changes execution policy or
  downloads from the network. Commands read, build and test; nothing else. This denylist is a
  guard against accidents, not a sandbox: a determined author of the issue body can still run
  arbitrary code, which is what the trusted-authors allowlist is for.
- Results are written to `.agent-state/issue-<n>.acceptance.md` and inserted into the
  reviewer prompt (`{{ACCEPTANCE}}`) as authoritative. Any failure is appended to the
  mechanical-failure list, so the change goes back to the author with the real output and
  **no review round is spent**. A pass reaches the reviewer, whose instructions say the
  transcript settles "was it run", and their job on those checks is only "does the command
  actually test the criterion".
- The revision prompt carries the last transcript too, so the author is never asked for
  proof it cannot produce.

Two task-body defects are recognised before anything runs, because they cannot be fixed by
the author and otherwise cost whole tasks (in the case-study project, between two sessions
and six rounds each):

- **A check written as `powershell -NoProfile -Command "<text>"`.** Written that way it only
  works from `cmd.exe`: as a PowerShell line the double-quoted string expands every `$name`
  before the inner shell sees it, so the check fails on every run whatever the change
  contains. The intent is unambiguous ("run `<text>` in a fresh PowerShell") and every
  acceptance line already runs in a fresh `powershell -NoProfile`, so
  `Resolve-AcceptanceCommand` **unwraps the line and executes `<text>` directly as code**: the
  check really runs, with its intended meaning. At planning time the line is stored already
  unwrapped; at review time the transcript shows the executed form and the original. Only a
  nested line that cannot be unwrapped (arguments after the closing quote, a quote that does
  not close) and still contains `$` is reported as `NOT RUN (task-body defect)`, counted as
  passed so no revision is spent on it, with the reviewer told to judge that check from the
  diff. `scripts/test-supervisor.ps1` proves both halves with a real line of this shape:
  as written it fails, unwrapped it passes, and unwrapped it still fails on a file that does
  not parse.
- **A change that needs a file outside `## Owned paths`.** The implementer prompt tells the
  author to write a `## Blocked` section with `reason: out-of-scope` naming the paths instead
  of committing an empty revision. When the supervisor sees that section it stops the task at
  once, before any reviewer is paid, and the repair step widens the ownership (a rescope, free
  for the first three per task); it also clears `lastReviewedSha` so that, once the task
  body is widened, relabelling `agent-review` (not `agent-ready`) resumes from the existing
  commits instead of tripping the same-commit guard.

Output is truncated to 3,000 characters per command (first and last 1,500) before it is
pasted anywhere, so a chatty test does not inflate the reviewer prompt. A task with no fenced
block behaves exactly as before, and the reviewer is told nothing was executed.

"No review round is spent" means no reviewer is called; the automatic verdict still counts as
one of the `MaxRevisions` rounds and costs the author one revision session. What it cannot do
is repeat itself for nothing: if the checks fail again at the **same commit** — the author's
revision committed nothing, which is what an environmental failure (TEMP, `gh` login, a
network timeout) or a misunderstood task looks like — the task is failed with the check
output in the comment instead of spending the remaining rounds on identical results. A
revision that did commit something always gets its next round.

### Trusted authors

With `acceptance.trustedAuthors` set, acceptance commands run on the host only when every
person who could have chosen them is on the list (`Test-AcceptanceAuthority`,
`scripts/lib/trusted-authors.ps1`, with GitHub identities read by `Get-IssueIdentity` through the
GraphQL API): the task issue's author and its last body editor, and -- for a task the planner
created with the supervisor's own account -- the author and last editor of its parent objective,
because the planner derived the commands from that text. Otherwise every command of that task is
reported as `NOT RUN (untrusted author)`, counted as passed so no revision is spent, and the
reviewer judges those checks from the diff; the issue gets one comment. An objective written or
last edited by someone off the list is not planned at all: it is moved to `objective-failed`
with an explanation. A failed identity lookup fails closed. With no list configured the
supervisor logs a warning at startup and behaves as before. Exercised by
`scripts/tests/test-trusted-authors.ps1`.

GitHub records only the *last* editor of an issue body; a body edited by an untrusted person and
then touched again by a trusted one counts as trusted. On GitHub only the author and people with
triage or write access can edit an issue body, so in practice the list protects against issues
opened by outsiders.

### Follow-up review rounds are incremental

Each review round is a fresh reviewer session. Starting every round from nothing means
re-reading the full diff, `AGENTS.md` and large parts of the supervisor script to judge a
twenty-line fix; Codex reports a stable 35–50K tokens per round whatever the diff, so the
allowance goes on repeated discovery, not on any one round. Instead, the supervisor remembers the commit each verdict
was given for (`lastReviewedSha` in `issue-<n>.json`) and, from round 2 on, fills the
reviewer prompt's `{{PREVIOUS_ROUND}}` section with the previous verdict and
`git diff <lastReviewedSha> HEAD` (capped at `-IncrementalDiffChars`, default 12,000): verify
the old blocking findings against what changed, check the new hunks, read the full diff only
where a hunk cannot be judged alone. Round 1, and any round whose previous commit is no longer
on the branch, get the full-review instruction as before.

Two consequences of remembering the commit:

- A commit the reviewer already **rejected** is never reviewed twice. If a revision leaves the
  branch at the rejected commit, the task is failed with a pointer to the last verdict rather
  than paying for the same reading again. (A task the owner puts back to `agent-review` with
  its counter reset to 0 is round 1 again and gets a full review — that path is unchanged.)
- A commit the reviewer already **approved** is not reviewed again either: when the merge
  after an approval is deferred (push race, `gh` unreachable), the next cycle re-uses the
  approval for that commit and goes straight to the merge checks.

The handoff pasted into the reviewer prompt is capped at `-ReviewerHandoffChars` (default
3,500); the pull request body keeps the full text. The implementer prompt asks for a handoff
of facts under 40 lines for the same reason.

### Reasoning effort follows the task

The supervisor sets `run-agent.ps1 -CodexReasoning` per task. `Get-TaskReasoning` reads the task's `## Owned paths`: if every path is a document
(`.md`, `.txt`, `.yaml`, `.json`, or a directory under `docs/`), codex runs at
`-DocsReasoning` (default `low`) for that task's implementation,
reviews and revisions; anything touching code stays at `medium`. `-DocsReasoning medium`
turns this off. Claude has no such knob and is unaffected.

A rebuilt branch (`agent-ready`) is a new attempt: `Invoke-Implementation` resets the round
counters and the remembered commit in `issue-<n>.json`.

### Known limitation: the crash window around a worker launch

Recovery identifies a worker by PID and start time, and fails closed when it cannot positively
confirm one is gone. It does not enumerate surviving CLI descendants of an already-exited
wrapper. A crash in the very narrow window around a process launch can therefore still leave a
descendant the supervisor cannot see. This is accepted rather than fixed: the consequence is a
task that waits for a human to re-label it, the fix requires OS-level process tracking well
beyond what this single-machine pipeline warrants, and `status.json` plus the stranded-issue
sweep make the situation visible and recoverable in one action.

## Status file

Every cycle the supervisor writes `.agent-state/status.json`: what it is about to do, how many
issues sit in each state, how many are paused on quota, and each provider's health. Read that
one file to know where things stand instead of reconstructing it from the log, the issues and
the worktrees.

## Owner dashboard

`scripts/serve-dashboard.ps1`, started in the target repository's clone, serves a single
page, `docs/dashboard/index.html`, on `http://localhost:8765/` (loopback only, read-only, fixed
routes); it refreshes every 30 s from `dashboard.json` in the state directory.
`Write-Dashboard` writes that file every cycle (including `-DryRun` cycles, so a dry run can be
verified end to end) from what the loop already fetched: the queue by state (objective /
planned / ready / blocked / in progress / review / failed, with author, reviewer and review
rounds), each provider's readiness, pause reason and reset time, sessions of the last 24 h
parsed from `supervisor.log` (provider, mode, duration, outcome, and for codex the `tokens
used` figure from its run log), sessions and tokens in the last 5 h and 24 h, merges of the
last 24 h, the active lesson count and its five newest entries (id, date, source, hits — see
"Lessons loop" above; the page marks any entry dated within the last 24 h the same way it
already marks a time-based state elsewhere). The page also queries the
public status JSON of Anthropic, OpenAI and GitHub so a provider incident is visible next to
the queue. A `dashboard.json` older than six minutes shows a banner (host asleep or task
stopped). A failure to write the file is logged and otherwise ignored; nothing in the loop
depends on it.

Session token totals for finished sessions are cached per execution (`runId`: tag plus start
time) in `.agent-state/sessions.json`. Invocations use unique `-run-<uuid>` artifact/log tags;
heartbeat and worker ownership retain their logical phase tag. Repeated legacy tags remain
separate sessions. Cache entries must match provider and completion time, and overwritten
legacy Codex/Copilot artifacts cannot supply older sessions' usage: unknown counts stay null.
Delete the cache to rebuild from surviving evidence; deleted artifacts cannot be recovered.
Codex totals come from its transcript token-count records when
available, with the text `tokens used` regex as the fallback. The dashboard-only blocked,
failed and planned label queries are throttled (`Test-QueueLabelsStale`) and their last
successful fetch time is recorded as `queueFetchedAt`. `dashboard.json.meta.exportMs` is the integer export duration in
milliseconds, and `dashboard.json.meta.githubCalls` is the integer number of `gh` invocations
in that cycle. The footer displays these as the export duration in seconds and the GitHub call
count, alongside the 30-second refresh and usage-page links.

### Plan and quota fields

Each `providers.<name>` object carries a `plan` field (the account's plan label, or `$null`
when it could not be read) and a `quotas` array (each entry a `{ label, usedPercent,
remaining, total, resetsAt, source }` record; possibly empty). `providers.copilot` also
carries `noPremiumRequests`, set when the account's plan grants no premium-request allowance
at all (rather than reporting a meaningless 0/0 quota for it). These are read from three
official sources, one per provider, each with its own rate limit:

- **Codex** — its own local session transcripts under `~/.codex/sessions/` (`Get-CodexQuota`).
  Only the 5 most-recently-modified files are ever opened per call; beyond that there is no
  additional rate limit, since no network call is made.
- **Copilot** — `gh api copilot_internal/user` (`Get-CopilotQuota`). Called at most once per
  supervisor cycle; the result is cached in `.agent-state/copilot-quota-cache.json` and reused
  for any call within 110 s of the last successful fetch (just under the poll interval, so a
  cycle that runs slightly early still reuses the previous cycle's call).
- **Claude** — Anthropic's `GET /api/oauth/usage` (`Get-ClaudeQuota`), authenticated with the
  OAuth access token Claude Code already stored locally after login. Called at most once every
  5 minutes; the result is cached in `.agent-state/claude-quota-cache.json`. An HTTP 429 from
  the endpoint backs off further calls for 30 minutes, also recorded in that cache file so the
  backoff survives a supervisor restart.

This call uses an undocumented endpoint and is best-effort: it runs on the owner's own host,
under the owner's own Claude account and OAuth session — the same credentials
Claude Code itself already holds locally, not a separate or elevated grant. The raw response
body and the access, refresh and ID tokens are never logged, cached or otherwise written to
disk; only the two derived percentages and reset times per window leave `Get-ClaudeQuota`.

Each call runs in its own isolated runspace with a 2 s wall-clock budget
(`Invoke-QuotaReaderBounded`): `Write-Dashboard` waits at most 2 s on the call's async handle
and, if the reader has not returned by then, abandons that runspace, logs a one-line warning,
and moves on with the last cached (or empty) result. A stalled network call or a stuck `gh`
process is therefore never able to block the polling loop, not merely logged after the fact.

The quota bars show each provider's own official windows (Codex and Claude both report a 5 h
and a 7-day window; Copilot's quota categories reset monthly), read from the sources above
rather than approximated from the supervisor's own log. For Codex and Claude the page shows
the real remaining quota directly instead of only linking out to a usage page.

### Live status

The dashboard also reads `.agent-state/live.json`, a short-lived heartbeat updated about
every 20 seconds by `Invoke-Agent` and during the supervisor's own steps. Its fixed shape is
`updatedAt`, `step`, `issue`, `role`, `provider`, `tag`, `startedAt`, `elapsedSeconds`,
`deadline`, and `lastAction` (`at`, `kind`, `summary`). The four dashboard roles are author,
reviewer, planner, and supervisor; the card shows the provider, issue, elapsed time, and last
action for the current role, and `waiting` for the other roles. The page treats
`Date.now() - updatedAt > 90000` as stale when `step` is not `idle` and shows a warning; a
missing or stale entry falls back to the dashboard's next action for the headline.

## Known pitfalls and how they are handled

Each entry names a classic failure mode of an unattended orchestrator and what the supervisor
does about it.

- **Concurrent supervisors / races.** Prevented by the exclusive startup lock (above); within
  one process the poll loop is single-threaded, so there is no concurrent mutation of the same
  issue by that process. Stray worker processes that outlive a dead supervisor are handled by
  the worker-liveness check in recovery for the `agent-in-progress` path, and by
  `Get-LiveWorkerForIssue` inside `Invoke-Review` for a mid-revision or mid-review restart (see
  "Mid-revision and mid-review worker liveness" above) — both fail closed: a launch-intent
  record written before the worker's process ever starts (see "Durable worker ownership" above)
  means a missing record almost never coincides with a live worker, and the rare case that
  isn't fully covered (`pid <= 0`, or the worktree was touched too recently to trust a quiet
  worktree) marks the task `agent-failed` or defers rather than reclaiming/launching a second
  writer on a guess. Approving stale code because a revision's push hadn't landed yet is closed
  by the `pendingPush` flag (persisted before the revision worker launches, not after) plus
  the pre-merge `headRefOid` comparison (see "Merge" and "Recovering a revision that finished but
  was not confirmed pushed" above). A worker ownership record that fails to write at all is
  treated as fatal for that run (`Unsafe`), blocking validation/push/merge instead of trusting an
  exit code from a process nothing can positively identify anymore.
- **GitHub/CLI unreachable mid-task.** `Invoke-Gh`/`Invoke-GhJson` surface a non-zero `Code`.
  `Find-ExistingTaskIssues` distinguishes a failed search from a genuinely-empty one and
  the two callers (`Invoke-Planning`'s duplicate check, `Check-ObjectiveDone`'s fallback) defer
  rather than proceeding as if nothing was found. `Unblock-Dependants` and
  `Check-ObjectiveDone` likewise require every prerequisite/child read to succeed before
  unblocking a task or declaring an objective done; a single failed read defers the decision
  instead of being treated as "resolved". Because those two are otherwise only invoked in-line
  right after a merge in the same process, `Invoke-Reconciliation` re-runs both for every
  `objective-planned` objective on **every** poll cycle (regardless of what else that cycle did),
  so a deferred decision — or one that never got its in-line trigger at all because the
  supervisor restarted between the merge and the call — is always retried on the next poll
  instead of staying stuck until another unrelated merge happens to touch the same objective.
  Other `gh` calls (label edits, comments) still don't hard-fail on a transient error; worst case
  is a stray label, self-healed by the next cycle's `agent-in-progress` recovery sweep or
  reviewed by a human — not duplicate work or data loss.
- **Malformed/partial planner or reviewer JSON.** `Extract-Json` returns `$null` on parse
  failure; an empty/missing `plan.tasks` or `verdict.verdict` is treated as a failure
  (`objective-failed`, or a retried-then-failed review). Each individual task object is also
  validated (non-empty `title`/`goal`/`provider`) before use; a malformed task is skipped and
  logged, the rest of the plan proceeds. A task that depends on a key which was skipped or
  failed to create is also skipped (see Failure policy), instead of running unblocked.
- **Two tasks touching the same files.** Not prevented up front (the planner is asked to keep
  `owned_paths` disjoint); if it happens anyway, the only runtime consequence is a merge
  conflict, which `Invoke-Review`'s rebase step already turns into a clean `agent-failed`.
- **Existing worktree / existing remote branch.** `Invoke-Implementation` and `Invoke-Recovery`
  always remove any existing worktree and local branch before creating fresh ones from
  `origin/main`; the final push is `--force`, so a leftover remote branch is overwritten, not
  left to conflict.
- **PR closed by a human.** `Find-PR` filters `--state open`; review fails cleanly
  (`agent-failed`) when no open PR is found for the branch.
- **Encoding.** All supervisor-written files use explicit no-BOM UTF-8 (`Write-Utf8File`).
  Agent-written files (`HANDOFF.md`) are the one place a BOM could leak in; `Read-Handoff`
  strips a leading `U+FEFF`, the same as `Get-Field` already does for issue bodies.
- **Array unrolling.** `Invoke-GhJson` explicitly unrolls PowerShell 5.1's "a JSON array
  becomes one object" quirk via `@(... | ForEach-Object { $_ })`.
- **`$LASTEXITCODE` after a pipeline.** Every pipeline that precedes a `$LASTEXITCODE` check
  pipes only to `Out-Null` (a cmdlet, not a native command), which never resets it.
- **`Write-Output` leaking into a function's return value.** `Write-Log` deliberately uses
  `Write-Host` for exactly this reason; no function in these scripts calls `Write-Output`.
- **Native-argument quoting.** Most external calls use PowerShell's array-splat (`& cmd @args`),
  which quotes each element correctly *unless an element itself already contains a literal
  double quote* — Windows PowerShell 5.1 then wraps the whole element in one more pair of
  quotes without escaping the ones already inside it, corrupting the argument.
  `Find-ExistingTaskIssues` builds such a phrase (`"Objective: #12" in:body`, with the
  objective's number) and escapes its embedded quotes as `\"`, which survives the wrap intact
  (the older doubled-quote form stopped working with the September 2026 update of Windows
  PowerShell 5.1).
  `Invoke-Agent`'s `$argList` for `Start-Process -ArgumentList` (a single joined command line,
  not an array-splat) wraps path-bearing values in literal quotes for the same underlying
  reason and has no embedded quotes to double.

## Running

From the target repository's main clone, with `<tool>` the path of this repository:

```powershell
<tool>\scripts\agent-supervisor.ps1 -ConfigPath .\agent-orchestrator.json -DryRun -Once   # inspect the queue and tool availability
<tool>\scripts\agent-supervisor.ps1 -ConfigPath .\agent-orchestrator.json -Once           # do one unit of work
<tool>\scripts\agent-supervisor.ps1 -ConfigPath .\agent-orchestrator.json                 # loop
<tool>\scripts\install-supervisor-task.ps1 -ConfigPath .\agent-orchestrator.json -Start   # register the always-on scheduled task
<tool>\scripts\serve-dashboard.ps1                                                       # the dashboard on http://localhost:8765/
```

Logs and per-run prompts/outputs are in the state directory (`.agent-state/` by default; add it
to the target repository's `.gitignore`).

## Self-test

`scripts/test-supervisor.ps1` is a self-contained check of the pure helper functions in
`scripts/agent-supervisor.ps1` (among others `Get-Field`, `Get-IssueRefs`, `Extract-Json`, `Load-State`,
`Save-State`, `Fill-Template`, `Other-Provider`, `Read-Handoff`) and
`scripts/run-agent.ps1` (`Get-QuotaBlock`). It touches neither GitHub nor any agent CLI, and
does not dot-source either script directly: dot-sourcing `agent-supervisor.ps1` would run the
module-level code at the bottom of the file, which requires the GitHub CLI, checks the
supervisor's lock file, and enters an infinite poll loop. Instead it parses each script's
text with `[System.Management.Automation.Language.Parser]::ParseFile`, locates each named
function's `FunctionDefinitionAst`, and defines only that function (from its extent text) in
its own scope, so nothing else in either file ever executes.

Run it with:

```powershell
.\scripts\test-supervisor.ps1
```

Every check prints one line starting with `PASS` or `FAIL`; a summary line follows, and the
script exits non-zero if anything failed. It uses only temporary files/directories under
`$env:TEMP`, cleans them up, and finishes in well under a minute. Each helper's checks run
inside a try/catch: an unexpected error (for example, a temp directory that cannot be
created because of permissions) is reported as an explicit `FAIL` for that helper rather than
silently skipping it or aborting the rest of the script. After all checks run, the script
also cross-checks that every required helper produced at least one result line; if a section
aborted early and some of its checks never ran, that is reported as an additional `FAIL`
instead of letting a partially-skipped run report success.

```powershell
.\scripts\test-supervisor.ps1 -DryRun
```

`-DryRun` additionally launches `scripts\agent-supervisor.ps1 -Repository <repo> -DryRun -Once`
(a read-only inspection of the queue; `<repo>` is `$env:AGENT_TEST_REPOSITORY` or a public
sample repository) with a short timeout, as a smoke check that the real script still starts and
exits cleanly end-to-end. It runs that child with its working directory set to a throwaway
folder under `$env:TEMP`; since the supervisor resolves its
default state directory relative to its working directory, that state also lands inside the
same throwaway folder, fully isolated from the worktree's own `.agent-state/`, on whatever
drive `$env:TEMP` happens to be -- no cross-drive path juggling needed. The temporary folder
is removed afterwards. Both the `gh auth status` check and the child run itself are
time-bounded; a child that does not exit in time is killed (via `taskkill /T`, since Windows
PowerShell 5.1's `Process.Kill()` cannot end a process tree) rather than left running.
Because `agent-supervisor.ps1` requires the GitHub CLI to be installed and authenticated even
in `-DryRun` mode, this smoke check prints a clearly labelled `SKIP` line instead of a false
`PASS` (or an unexplained `FAIL`) when the GitHub CLI is missing, not authenticated, or
unresponsive.
