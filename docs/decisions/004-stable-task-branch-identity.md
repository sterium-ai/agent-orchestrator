# ADR 004: Task branch identity survives title edits

_Originally ADR 019 in the project where the pipeline was developed; issue numbers refer to that
project's history._

- Date: 2026-09-21
- Status: accepted; independently reviewed

## Problem

Task #273 had an open PR (#313) and a preserved checkout. Editing its title
changed the slug reconstructed by review/recovery, so the supervisor reported
that no PR existed and incorrectly recommended restarting implementation.

## Decision

Use the title only to name a new task branch. Resolve existing identity from
the checkout and persisted `branch` field; require both to agree when present.
For legacy tasks without either, look up an open PR with the exact
`agent/issue-<number>-` prefix. Reject ambiguity, foreign/detached checkouts,
unreadable state and missing identity rather than guessing from a new title.
Discovery is bounded to 300 open PRs: absence defers recovery safely, and an
integrator can reconcile an older branch explicitly.

Persist identity before implementation can recreate a checkout, and when a
legacy task enters review. A failed write stops that operation. Failure advice
must preserve work until the operator establishes whether a fresh implementation
is actually intended. This does not reset correction budgets or pending work,
automatically requeue failed tasks, or change review/merge gates.

## Validation and rollout

The regression test failed against the old resolver after a title edit. It now
uses a real Git checkout and exercises saved/actual conflicts, another task's
branch, legacy PR discovery, ambiguity, empty/failed discovery and failure
advice. Revision-flow coverage verifies that failed identity persistence causes
no checkout deletion, Git mutation or author launch.

Adopt through the existing supervisor self-update after its active worker
finishes. No forced restart, live-state rewrite, paid-model launch or data
migration is required. The additional state field is backward compatible.
