# Decision records

Architecture decisions about the orchestrator itself. They were written while the pipeline ran a
real project and renumbered for this repository; each record notes its original number, and
issue numbers inside them refer to that project's history.

| ADR | Decision | Originally |
| --- | --- | --- |
| [001](001-agent-ownership-and-review.md) | Phase-based agent ownership; the reviewer is always a different agent from the author | 002 |
| [002](002-workflow-reliability.md) | Unique per-run artifact tags, durable pending corrections, a cumulative revision budget | 013 |
| [003](003-bounded-expert-recovery.md) | One bounded expert correction session for a persistently stuck task | 014 |
| [004](004-stable-task-branch-identity.md) | Task branch identity survives issue-title edits | 019 |
