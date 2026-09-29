# ADR 003: One expert correction for persistent task blockage

_Originally ADR 014 in the project where the pipeline was developed._

- Date: 2026-09-20
- Status: requested by owner; implementation independently reviewed

The owner requested the strongest available model of each vendor at medium effort, with full
permissions, when a task gets stuck, and explicitly chose diagnosis AND correction on the
existing branch, followed by independent review. This extends ADR 002 without changing ordinary
model routing.

## Decision

Use the existing revision lifecycle, not another supervisor or parallel writer. Queue one
durable expert revision when a finding persists across three reviews, a revision ceiling is
reached, or ordinary repairs are exhausted. Require an existing task worktree; never use the
supervisor checkout as an expert working directory. Missing-worktree/preflight cases retain
ordinary repair and owner escalation.

Keep author ownership when possible: Claude -> `models.claudeExpert`, Codex -> `models.codexExpert`
(configuration; the defaults are `claude-fable-5-1` and `gpt-6-astra`).
Copilot -> Codex requires a successful task-provider reassignment to Codex/Claude before
dispatch. Thus the expert is always followed by a different reviewer provider. Clear old
approval and failure-comparison memory before the expert starts.

Medium effort and a 45-minute timeout apply only to that invocation. Full local permissions
use the CLIs' explicit bypass flags. This grants host-wide execution capability, not merely
extra task paths; it is intentionally scoped to the expert invocation, as the owner requested.
The prompt retains owned paths/contracts and prohibits unrelated host changes, credentials,
live-supervisor execution/state mutations and direct publication. Technical postconditions
still enforce ownership, tests, independent review and the exact reviewed commit at merge.

Persist `pendingRevision.expert/provider/model` and `expertAttempts`. Never reset the expert
budget on repair or branch recreation. Quota refusal refunds the attempt while preserving
the exact pending profile. Other failures consume the one attempt; there is no silent model
fallback. Allow one expert after the normal cumulative ceiling without resetting the total:
the maximum becomes the configured normal ceiling plus one, not an unlimited retry ladder.
The timeout is per execution, not accumulated across quota retries; provider quota handling
retains existing behavior even if the provider edited some files before its quota refusal.

Evidence excerpts are bounded (6,000 characters per source, latest three review artifacts),
with full local paths for targeted follow-up. Retain the owner objective, task, failure,
handoff, checks and previous repair hint. Existing history stays on the branch. No extra paid
diagnosis stage is added before the expert correction.

## Validation and rollout

Regression fixtures exercise routing, counters, quota/restart, independent review, failed
assignment, failed persistence and live-worker exclusion. The real runner is exercised with
a fake provider executable to assert exact model, medium and full-access flags, ordinary
policy preservation and rejection of privileged read-only sessions. The heartbeat test
verifies forwarding the expert flag to a dummy child. Tests never invoke paid models.

Model identifiers are configuration, checked against the installed CLIs when the decision was
taken. Account access to a model is not inferred from provider availability. A model access
error is preserved for diagnosis. No changes to product code or stored data.

Adopt through normal supervisor self-update after merge, without interrupting active work.
Rollback only after a worker finishes: older code would not interpret queued expert intent.
No live state migration or manual deletion is part of deployment.
