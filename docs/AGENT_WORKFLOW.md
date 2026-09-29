# Agent workflow

This document defines the collaboration contract the pipeline assumes between the agents (and
any human) working on a target repository. The supervisor automates most of it; the rules still
apply when a person steps in.

## Work allocation

Break work into vertical, reviewable slices rather than assigning broad systems to several
agents. Assign by **phase and ownership area**, not by a rigid model stereotype. Claude Code,
Codex and Copilot may all design, specify, implement, test, or refactor when they own the
relevant subsystem ([ADR 001](decisions/001-agent-ownership-and-review.md)).

The owner writes the subsystem contract into the repository. The reviewer is always a different
agent from the author and receives that contract with the diff. One human or agent acts as the
integrator for each change.

## Contract before code

Before implementation, write down (the planner does this in every task issue):

```text
Goal:
Non-goals:
Source of truth:
Owned paths:
Acceptance checks:
Acceptance commands:
```

Prefer data and interfaces that can be tested without a UI. Keep core rules separate from
presentation, and make identifiers, storage formats and event payloads explicit. When behaviour
is uncertain, mark it as an assumption rather than encoding it as fact.

## Branch and handoff protocol

1. One branch for one coherent change (`agent/issue-<n>-<slug>`, created by the supervisor).
2. The task's `## Owned paths` is the claim on files; nothing outside it changes.
3. Work starts from a fresh `origin/main`.
4. Commit the smallest complete increment. Do not mix formatting, renames, or unrelated fixes
   into the feature.
5. The handoff (`.agent-state/HANDOFF.md`) reports the branch, changed files, contract impact,
   validation and known limitations.
6. The next agent consumes the branch or the pull request; it never copies files manually from
   another worktree.

If two tasks need the same file, split the work at a stable interface or let one finish first.
Do not resolve overlapping edits by choosing whichever version is newest without checking the
contract.

The reviewer handoff includes the contract, acceptance criteria, changed paths and validation
results. A reviewer comments or requests changes; it never authors the change it is reviewing.

## Single source of truth

There is one canonical location for each kind of information:

| Information | Canonical location |
| --- | --- |
| Behaviour and contracts | the implementation, its tests, and the architecture documents |
| Design decisions and open questions | `docs/decisions/` and the linked issue |
| Protected material (vendored code, fixtures owned elsewhere) | the paths `AGENTS.md` lists as protected |
| Collaboration status | the issue, pull request and branch |

When implementation disagrees with a note, update the design record and explain why. Do not
maintain a second hand-edited copy of code or data just for an agent.

## Sync and conflict avoidance

- Work from the latest `origin/main`; the supervisor fetches it before every worktree.
- A conflict on an approved branch is resolved with a real `git merge origin/main` in the
  author's worktree, followed by a fresh review.
- Never force-push a branch another agent is using.
- Keep commits atomic so a conflict can be resolved by contract, not by reconstructing an
  entire session.
- Never touch the protected paths listed in `AGENTS.md`.

## Test and review gate

Each handoff states the exact commands run and their result. Before every review the supervisor
itself runs, on the host:

1. mechanical checks (PowerShell parse errors, `git diff --check`, protected paths, file budgets);
2. the project's test gate (`testGate.command`), when configured;
3. the task's own acceptance commands.

A missing test command is a repository limitation, not a passing test result.
