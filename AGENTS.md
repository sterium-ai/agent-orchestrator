# Agent instructions (this repository)

This repository holds the orchestrator itself: the supervisor scripts, the role prompts and the
pipeline's own tests. It is owned by the human integrator; agents driven by the pipeline never
edit it unless a task says so explicitly.

The rule book those agents obey inside a *target* repository is that repository's own
`AGENTS.md`; a template is in `docs/examples/target-project-AGENTS.md`.

## Rules for changes here

- Windows PowerShell 5.1 is the baseline: no PowerShell 7-only syntax (`??`, `?.`, ternaries,
  `&&`/`||` pipeline chains). Scripts that contain non-ASCII characters must be saved as UTF-8
  with a BOM; prefer plain ASCII.
- Pure logic goes into a dot-sourceable file under `scripts/lib/` with its own test under
  `scripts/tests/`; `agent-supervisor.ps1` wires it in.
- Tests never call GitHub for writes, never launch a paid model, and clean up everything they
  create under `$env:TEMP`.

## Validation

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-supervisor.ps1 -DryRun   # helpers + a dry-run smoke check
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\tests\<name>.ps1              # one suite
node scripts\test-dashboard-bars.js                                                      # dashboard rendering
```

Run `git diff --check` before opening a pull request. Never commit credentials; see
`docs/AGENT_CREDENTIALS.md`.
