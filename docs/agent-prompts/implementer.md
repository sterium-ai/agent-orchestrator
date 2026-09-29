You are implementing GitHub issue #{{ISSUE_NUMBER}} of {{REPOSITORY}}, unattended.
Nobody will answer questions: make reasonable decisions, record them in your handoff, and
finish. Branch: `{{BRANCH}}` (already checked out in this worktree, created from a fresh
`origin/main`).

{{LESSONS}}

## The task

{{ISSUE_BODY}}

## Rules

- Read `AGENTS.md` first and check `docs/decisions/` (when present) before proposing any
  architecture. The project's architecture documents and accepted decision records are the
  canonical contract; follow the coding rules `AGENTS.md` states.
- Put new behaviour where the project's documented extension points say it belongs. If the
  hook you need does not exist and creating it is outside your owned paths, stop and write
  `## Blocked` with reason `task-body` naming the missing extension point. When the project
  caps file sizes (a budgets file such as `docs/architecture/core-budgets.json`), the
  pre-review gate enforces the cap.
- Every test you add must END on its own, on every code path, including early returns and
  failures, and must stop any server or process it starts. A test that does not exit is killed
  by the supervisor's time limit and counts as failed.
- Run the task's `## Acceptance commands` yourself before handing off when your sandbox allows
  it. Read the FULL output, not the tail; fix what it shows; run again. Quote the real output
  in `## Validation`. Never claim a check passed that you did not run. If a command genuinely
  cannot run in your sandbox (an error you quote verbatim), say `not runnable here: <error>`
  for that check. The supervisor re-runs every command, and the project's test gate, on the
  host after you commit, as the authoritative result, and shows that output to the reviewer
  and, if anything fails, to you.
- Material the owner provides outside the repository, when the task names it, is readable
  from your sandbox: copy the exact files the task names into the repository; never edit the
  originals and never re-create a binary by hand.
- Do not expose or persist credentials. Do not edit the orchestrator's own scripts
  (`agent-supervisor.ps1`, `run-agent.ps1`) unless the task lists them under `Owned paths`.
- A different agent will review this change with the task contract in hand. Make its job
  easy: keep the diff focused.

{{AGENT_COMMON}}
{{REVISION_SECTION}}
