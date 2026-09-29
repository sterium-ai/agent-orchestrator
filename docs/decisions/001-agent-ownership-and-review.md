# ADR 001: Phase-based agent ownership and independent review

_Originally ADR 002 in the project where the pipeline was developed._

- **Status:** accepted
- **Date:** 2026-09-10
- **Owners:** project integrator

## Context

Claude Code, Codex, and GitHub Copilot can all perform design, implementation,
testing, and review. Rigidly assigning one model to “thinking” and another to
“typing” creates unnecessary handoffs and duplicated context.

## Decision

Assign agents by project phase and ownership area. The owner of a subsystem
records its contract in the repository and may be Claude Code, Codex, Copilot,
or a human. Only one owner edits a file or subsystem at a time.

The reviewer is always a separate agent from the author. Review requests
include the contract, acceptance criteria, changed paths, and validation
results, not only a diff.

## Consequences

- Agent selection can follow availability and context instead of stereotypes.
- Repository contracts eliminate copy-pasting design between agent windows.
- Review independence is a strict quality gate.
- Parallel work remains safe when ownership boundaries do not overlap.
