# ADR 001: Phase-based agent ownership and independent review

> **In short:** work is assigned by project area rather than by a fixed idea of what each AI is
> good at, and the agent that wrote a change never approves it.

- **Status:** Accepted
- **Date:** 2026-09-10

## Context

Claude Code, Codex and GitHub Copilot can all perform design, implementation, testing and
review. Rigidly assigning one model to "thinking" and another to "typing" creates unnecessary
handoffs and duplicated context.

## Decision

Assign agents by project phase and ownership area. The owner of a subsystem records its
contract in the repository and may be Claude Code, Codex, Copilot or a person. Only one owner
edits a file or subsystem at a time.

The reviewer is always a different agent from the author. Review requests include the
contract, acceptance criteria, changed paths and validation results, not only a diff.

## Consequences

- Agent selection can follow availability and context instead of stereotypes.
- Contracts kept in the repository remove the need to copy design between agent sessions.
- Review independence is a strict quality gate.
- Parallel work remains safe when ownership boundaries do not overlap.
