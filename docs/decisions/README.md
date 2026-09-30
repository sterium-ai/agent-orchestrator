# Decision records

> **In short:** short documents that explain why the orchestrator works the way it does, one
> decision per file.

Architecture decision records (ADRs) about the orchestrator itself. They were written while the
pipeline delivered the project described in the [case study](../case-study.md). Files are named
`NNN-short-title.md`; each has a status, a date, the context that prompted it and the decision.

| ADR | Decision |
| --- | --- |
| [001](001-agent-ownership-and-review.md) | Phase-based agent ownership; the reviewer is always a different agent from the author |
| [002](002-workflow-reliability.md) | Unique per-run artifact tags, durable pending corrections, a cumulative revision budget |
| [003](003-bounded-expert-recovery.md) | One bounded expert correction session for a persistently stuck task |
| [004](004-stable-task-branch-identity.md) | Task branch identity survives issue-title edits |
