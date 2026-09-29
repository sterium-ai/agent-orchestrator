# Agent instructions

<!--
Template for the AGENTS.md of a repository driven by the agent orchestrator. Copy it to the
root of the target repository and replace every <...> placeholder. The planner, the authors,
the reviewer and the repair step are all told to read this file first, so it is where the
project's own rules belong. Keep it short and concrete: every line is read on every task.
-->

This file is the repository-wide source of operating rules for Claude Code, Codex, GitHub
Copilot, and human contributors. More specific `AGENTS.md` files may add constraints for a child
directory; they must not weaken these rules.

## Project and validation

<One paragraph: what the project is, its language and framework, where the code lives.>

The full test suite, which the supervisor also runs as its test gate before every review:

```text
<e.g. npm test>
```

Targeted checks an acceptance command can use:

```text
<e.g. npm test -- path/to/one.test.js>
<e.g. npm run lint>
```

A tool may be unavailable inside an agent sandbox; report that limitation instead of claiming a
passing test. For documentation and data-only changes, run `git diff --check` and validate
changed JSON files.

## Protected paths

Never edit these, whatever a task says (mirror them in `ownership.protectedPaths` in the
supervisor configuration so the pre-review gate enforces it):

- `<e.g. vendor/>`
- `<e.g. third_party/>`

## Coding rules

- <Architecture boundaries, e.g. "domain code under src/core/ never imports from src/ui/".>
- <Determinism or purity rules, e.g. "no wall-clock time or global randomness in core logic".>
- <Serialization rules, e.g. "every stored format is versioned and has a migration test".>
- Every test ends on its own on every code path and stops any server or process it starts.

## Source of truth

**Check `docs/decisions/` before proposing architecture.** When behavior or a public data shape
changes, update the relevant contract, schema, example and test, and add a short numbered
decision record when the decision crosses a boundary. Give reviewers the contract and acceptance
criteria together with the diff.

## Adding behaviour

<Name the extension points: where a new feature, a new data type, a new endpoint belongs, and
what is a defect (for example a second implementation of an existing mechanism). If
`docs/architecture/core-budgets.json` caps file sizes, say that raising a budget requires a
decision record in the same change.>

## Ownership and review

Assign work by phase and ownership area, not by assumptions about model capability. The agent
that owns the area writes its contract into the repository and is the author for that change.
Only one agent may own a file or subsystem at a time. The reviewer must be a different agent
from the author and receives the contract, acceptance criteria and validation results alongside
the diff. A reviewer may comment or request changes but must not author the reviewed change.

The orchestration itself (the supervisor scripts and `docs/agent-prompts/`) is owned by the
human integrator. Agents do not modify it unless a task says so explicitly.

## Git discipline

One branch per coherent change (the supervisor names them `agent/issue-<n>-<slug>`). Work from a
fresh `main`, keep commits atomic, never force-push a shared branch, and do not mix generated
files or unrelated cleanup into a feature.

Every handoff reports: branch, owned paths touched, contract impact, validation commands and
results, known limitations, and the next action.
