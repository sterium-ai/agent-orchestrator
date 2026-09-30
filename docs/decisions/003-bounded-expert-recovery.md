# ADR 003: One expert correction for persistent task blockage

> **In short:** when a task stays stuck after the normal repair steps, the pipeline makes exactly
> one extra attempt with the strongest available model, and that attempt is still checked by an
> independent reviewer before anything merges.

- **Status:** Accepted
- **Date:** 2026-09-20
- **Extends:** [ADR 002](002-workflow-reliability.md)

## Context

Some tasks stay blocked after the ordinary repair ladder (hints, task patches, rescopes,
rewrites, an author switch). The owner asked for the strongest available model of each
provider, at medium effort and with full permissions, to diagnose AND correct such a task on
its existing branch, followed by independent review. Ordinary model routing is unchanged.

## Decision

Use the existing revision lifecycle, not another supervisor or a parallel writer. Queue one
durable expert revision when a finding persists across three reviews, a revision ceiling is
reached, or ordinary repairs are exhausted. Require an existing task worktree; never use the
supervisor checkout as an expert working directory. Cases without a worktree, or that fail
preflight, keep the ordinary repair step and escalation to the owner.

Keep author ownership when possible: Claude uses `models.claudeExpert`, Codex uses
`models.codexExpert` (configuration; the defaults are `claude-fable-5-1` and `gpt-6-astra`).
A Copilot-authored task is first reassigned to Codex (with Claude as reviewer); the expert
starts only after that reassignment succeeds. The expert is therefore always followed by a
reviewer from a different provider. Old approval and failure-comparison memory is cleared
before the expert starts.

Medium effort and a 45-minute timeout apply only to that invocation. Full local permissions
use the CLIs' explicit bypass flags. This grants host-wide execution capability, not merely
extra task paths, and is deliberately limited to the expert invocation. The prompt keeps the
owned paths and contracts and prohibits unrelated host changes, credential access, changes to
the live supervisor or its state, and direct publication. Technical postconditions still
enforce ownership, tests, independent review and the exact reviewed commit at merge.

Persist `pendingRevision.expert/provider/model` and `expertAttempts`. Never reset the expert
budget on repair or branch recreation. A quota refusal refunds the attempt while preserving
the exact pending profile. Other failures consume the one attempt; there is no silent model
fallback. One expert may run after the normal cumulative ceiling without resetting the total:
the maximum becomes the configured normal ceiling plus one, not an unlimited retry ladder.
The timeout is per execution, not accumulated across quota retries; provider quota handling
keeps its existing behaviour even if the provider edited some files before its quota refusal.

Evidence excerpts are bounded (6,000 characters per source, the latest three review
artifacts), with full local paths for targeted follow-up. The owner's objective, the task, the
failure, the handoff, the checks and the previous repair hint are included. Existing history
stays on the branch. No extra paid diagnosis stage is added before the expert correction.

## Validation and rollout

Regression fixtures exercise routing, counters, quota and restart handling, independent
review, failed reassignment, failed persistence and live-worker exclusion. The real runner is
exercised with a fake provider executable to assert the exact model, medium effort and
full-access flags, the preservation of ordinary policies, and the rejection of privileged
read-only sessions. The heartbeat test verifies that the expert flag is forwarded to a dummy
child process. Tests never invoke paid models.

Model identifiers are configuration and were checked against the installed CLIs when the
decision was taken. Access to a model is not inferred from provider availability; a model
access error is preserved for diagnosis. No product code or stored data changes.

Adopt through the normal supervisor self-update after merge, without interrupting active work.
Roll back only after a worker finishes: older code would not interpret queued expert intent.
No live state migration or manual deletion is part of deployment.
