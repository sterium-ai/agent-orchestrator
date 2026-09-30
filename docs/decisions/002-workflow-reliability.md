# ADR 002: Preserve execution identity and correction progress

> **In short:** every agent run keeps its own records, a correction that is owed is written down
> before it starts, and a task has a lifetime limit on correction attempts, so no restart or
> repair can make the pipeline lose track of work or retry forever.

- **Status:** Accepted
- **Date:** 2026-09-20
- **Scope:** supervisor, task preparation and independent review

## Context

An audit of two long-running tasks in the case-study project found three weaknesses:

- Both tasks repeatedly needed owned paths they did not have, persistence changes their briefs
  prohibited, and fixes for state transitions their tests did not exercise.
- One task had run nine correction sessions, not the two its (reset) counter showed. Reused
  artifact tags had overwritten earlier outputs and borrowed cached token counts from earlier
  runs.
- The other task repeatedly weakened an idle-time assertion instead of fixing the tool-selection
  behaviour that eventually explained the regression.

## Decision

1. A logical phase tag still identifies heartbeat and worker ownership. Every invocation
   writes artifacts and lifecycle log records under a unique `-run-<uuid>` tag. Historical
   log sessions use tag plus start time as identity. Cache hits must match provider and
   completion time; overwritten legacy Codex/Copilot files cannot supply older runs' tokens.
   Unknown usage stays null. This does not reinterpret the providers' token or billing units.
2. A successful rescope, hint, task patch or rewrite with an existing pull request queues a
   durable `pendingRevision` with evidence for the author. It does not pay a new reviewer to
   repeat the same request. `pendingPush` is set only when a correction is about to launch,
   preserving the existing worker/restart checks. After the push, independent review is still
   mandatory.
3. `totalRevisionAttempts` survives all repair-counter resets. Existing tasks initialise it
   from all correction launches in the append-only log, excluding quota refusals, with the
   old counter as a lower bound. `MaxTotalRevisions` defaults to 12; at the ceiling the task
   reports failure for diagnosis without deleting its commits or approving the change.
   A quota refusal retains pending evidence and refunds the correction attempt. The normal
   per-attempt revision and repair ceilings remain in force too.
4. An individual blocking finding that persists for three reviews (two unsuccessful
   corrections) invokes the existing bounded repair diagnosis, even if new findings appear.
   A resolved finding does not transfer its streak to a different finding. Similarity remains
   the existing heuristic: it triggers diagnosis, never approval or an automatic contract waiver.
5. Task preparation verifies current owners, dependencies, schema and complete save/load
   implications. Runtime preflight catches contradictory `Blocked by` headers before an
   implementation starts. Semantic feasibility and transition tables are the author's and
   planner's responsibility, not another unconditional paid agent stage.
6. Behavioural revisions supply targeted reproduction and before/after evidence. Existing
   assertions remain binding unless the task, as authorised by the owner, changes their
   contract.

## Compatibility and rollout

No product code, data schema, model routing, concurrency, queue priority, scheduling interval,
independent approval or regression gate is removed. Existing worker filenames and
PID/start-time/deadline recovery remain compatible. Old issue state is read lazily; the live
`.agent-state` directory must not be rewritten manually during deployment. The normal
supervisor self-update at a cycle boundary adopts the change after merge; do not terminate a
live author or replace its worktree. Rollback is a normal Git revert after the current worker
finishes. Older versions ignore the extra state fields, but their telemetry and repair
limitations return; avoid rolling back while a pending correction awaits launch.

## Validation

- `scripts/tests/test-workflow-reliability.ps1`: historical duplicate tags, cache isolation,
  unknown legacy usage, cumulative migration and per-finding progress.
- `scripts/tests/test-revision-flow.ps1`: real orchestration functions with external effects
  stubbed; repair-to-author, quota, durable write failure, cumulative cap and restart paths.
- The existing supervisor, heartbeat, last-action, ownership and prompt tests.

Overwritten historical files cannot be recreated. Keep raw logs, and do not claim an exact
historical total where the evidence is gone. Future execution artifacts are preserved.
