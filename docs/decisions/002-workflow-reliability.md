# ADR 002: Preserve execution identity and correction progress

_Originally ADR 013 in the project where the pipeline was developed; issue numbers refer to that
project's history._

- Status: accepted for the owner's requested workflow reliability change
- Date: 2026-09-20
- Scope: supervisor, task preparation and independent review

## Evidence

Issues #271 and #272 repeatedly needed missing owned paths, persistence changes prohibited
by their briefs, and fixes for state transitions inadequately exercised by their tests.
At the audit cutoff, #271 had nine correction executions, not the two
left in its reset counter. Reused tags overwrote artifacts and borrowed cached token counts
from earlier executions. #272 repeatedly weakened an idle-time assertion instead of fixing
the tool-selection behavior that eventually explained the regression.

## Decision

1. A logical phase tag still identifies heartbeat and worker ownership. Every invocation
   writes artifacts and lifecycle log records under a unique `-run-<uuid>` tag. Historical
   log sessions use tag plus start time as identity. Cache hits must match provider and
   completion time; overwritten legacy Codex/Copilot files cannot supply older runs' tokens.
   Unknown usage stays null. This does not reinterpret vendors' token or billing units.
2. A successful rescope, hint, task patch or rewrite with an existing PR queues a durable
   `pendingRevision` with evidence for the author. It does not pay a new reviewer to repeat
   the same request. `pendingPush` is set only when a correction is about to launch, preserving
   existing worker/restart checks. After push, independent review is still mandatory.
3. `totalRevisionAttempts` survives all repair-counter resets. Existing tasks initialize it
   from all correction launches in the append-only log, excluding quota refusals, with the
   old counter as a lower bound. `MaxTotalRevisions` defaults to 12; at the ceiling the task
   reports failure for diagnosis without deleting its commits or approving the change.
   A quota refusal retains pending evidence and refunds the correction attempt. The normal
   per-attempt revision/repair ceilings remain in force too.
4. Persistence of an individual blocking finding for three reviews (two unsuccessful
   corrections) invokes the existing bounded repair diagnosis, even if new findings appear.
   A resolved finding does not transfer its streak to a different finding. Similarity remains
   the existing heuristic: it triggers diagnosis, never approval or automatic contract waiver.
5. Task preparation verifies current owners, dependencies, schema and complete save/load
   implications. Runtime preflight catches contradictory `Blocked by` headers before an
   implementation starts. Semantic feasibility and transition tables are the author's and
   planner's responsibility, not another unconditional paid agent stage.
6. Behavioral revisions supply targeted reproduction and before/after evidence. Existing
   assertions remain binding unless the owner-authorized task changes their contract.

## Compatibility and rollout

No product code, data schema, model routing, concurrency, queue priority, scheduling interval,
independent approval or regression gate is removed. Existing worker filenames
and PID/start-time/deadline recovery remain compatible. Old issue state is read lazily;
the live `.agent-state` directory must not be rewritten manually during deployment.
Normal supervisor self-update at a cycle boundary adopts the change after merge; do not
terminate a live author or replace its worktree. Rollback is a normal Git revert after the
current worker finishes. Extra state fields are ignored by older versions, but their old
telemetry/repair limitations return; avoid rollback while a pending correction awaits launch.

## Validation

- `scripts/tests/test-workflow-reliability.ps1`: historical duplicate tags, cache isolation,
  unknown legacy usage, cumulative migration and per-finding progress.
- `scripts/tests/test-revision-flow.ps1`: real orchestration functions with external effects
  stubbed; repair-to-author, quota, durable write failure, cumulative cap and restart paths.
- Existing supervisor, heartbeat, last-action, ownership and prompt tests.

Historical overwritten files cannot be recreated. Retain raw logs; do not claim an exact
historical total where the evidence is gone. Future execution artifacts are preserved.
