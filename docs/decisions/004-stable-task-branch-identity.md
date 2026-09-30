# ADR 004: Task branch identity survives title edits

> **In short:** renaming a task's issue no longer makes the pipeline lose track of the work
> already done for it.

- **Status:** Accepted
- **Date:** 2026-09-21

## Context

A task with an open pull request and a preserved checkout had its issue title edited. Review
and recovery rebuilt the branch name from the new title, so the supervisor reported that no
pull request existed and incorrectly recommended restarting the implementation.

## Decision

Use the title only to name a new task branch. Resolve an existing branch from the checkout and
the persisted `branch` field, and require both to agree when both are present. For legacy
tasks with neither, look up an open pull request with the exact `agent/issue-<number>-` prefix.
Reject ambiguity, foreign or detached checkouts, unreadable state and missing identity rather
than guessing from a new title. Discovery is bounded to 300 open pull requests: absence defers
recovery safely, and an integrator can reconcile an older branch explicitly.

Persist the identity before implementation can recreate a checkout, and when a legacy task
enters review. A failed write stops that operation. Failure advice must preserve work until the
operator establishes whether a fresh implementation is actually intended. This does not reset
correction budgets or pending work, requeue failed tasks automatically, or change the review
and merge gates.

## Validation and rollout

The regression test failed against the old resolver after a title edit. It uses a real Git
checkout and exercises saved/actual conflicts, another task's branch, legacy pull-request
discovery, ambiguity, empty and failed discovery, and failure advice. Revision-flow coverage
verifies that a failed identity write causes no checkout deletion, Git mutation or author
launch.

Adopt through the existing supervisor self-update after the active worker finishes. No forced
restart, live-state rewrite, paid-model launch or data migration is required. The additional
state field is backward compatible.
