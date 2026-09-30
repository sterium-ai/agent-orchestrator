# Documentation

> **In short:** a map of every document in this repository, grouped by what you want to do:
> try the tool, run it day to day, understand its design, or see what it achieved.

## Getting started

- [../README.md](../README.md): what the orchestrator is, a quick start, configuration and the security model.
- [HOW_TO_GIVE_OBJECTIVES.md](HOW_TO_GIVE_OBJECTIVES.md): how a product owner asks for work and reads the results, without touching code.
- [AGENT_CREDENTIALS.md](AGENT_CREDENTIALS.md): signing in the provider CLIs and GitHub, and preparing an isolated host.
- [examples/target-project-AGENTS.md](examples/target-project-AGENTS.md): template rule book for the repository the pipeline works on.

## Operating

- [AGENT_SUPERVISOR.md](AGENT_SUPERVISOR.md): complete behaviour reference: stages, checks, repair, recovery, dashboard.
- [AGENT_WORKFLOW.md](AGENT_WORKFLOW.md): the collaboration contract between agents and people (ownership, handoffs, gates).
- [agent-prompts/](agent-prompts/): the prompt templates for each role (planner, implementer, reviewer, repair step, expert recovery), the rules they share and the shipped lessons.
- [dashboard/index.html](dashboard/index.html): the owner dashboard page, served by `scripts/serve-dashboard.ps1`.

## Architecture and decisions

- [decisions/README.md](decisions/README.md): index of the architecture decision records.
- [decisions/001-agent-ownership-and-review.md](decisions/001-agent-ownership-and-review.md): phase-based ownership and independent review.
- [decisions/002-workflow-reliability.md](decisions/002-workflow-reliability.md): per-run identity, durable pending corrections, cumulative revision budget.
- [decisions/003-bounded-expert-recovery.md](decisions/003-bounded-expert-recovery.md): one bounded expert correction for a stuck task.
- [decisions/004-stable-task-branch-identity.md](decisions/004-stable-task-branch-identity.md): branch identity that survives issue-title edits.

## Case study

- [case-study.md](case-study.md): what the pipeline delivered on a real game project, where it struggled, and how the figures were measured.
- [../CHANGELOG.md](../CHANGELOG.md): release history.
