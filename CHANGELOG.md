# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-09-30

First public release. The pipeline previously ran inside a single project (see
`docs/case-study.md`); this release makes it usable with any GitHub repository.

### Added

- Supervisor that drives GitHub issues through labels: objective -> planner -> task issues ->
  implementer in an isolated git worktree -> host-side checks -> review by a different provider
  -> squash-merge of exactly the reviewed commit.
- Three providers (Claude Code, Codex, GitHub Copilot CLI) with quota detection, per-login
  cooldowns and reserve Codex logins.
- JSON configuration (`agent-orchestrator.example.json`) with command-line overrides; no default
  repository.
- Configurable test gate (`testGate.command`) run on the host before every review, replacing the
  engine-specific test runner the pipeline was born with.
- Trusted-authors allowlist (`acceptance.trustedAuthors`): acceptance commands run on the host
  only when the issue's (and, for planner-created tasks, the objective's) author and last editor
  are trusted; objectives from anyone else are not planned.
- Configurable ownership rules (tests that reference owned paths, companion files, protected
  paths, generated files, file budgets), agent shell-command allowlist, extra and
  sandbox-writable directories, orphan-process sweep, expert-recovery models.
- Custom author roles: `Role: <name>` selects `docs/agent-prompts/<name>.md` when it exists.
- `scripts/serve-dashboard.ps1`: loopback-only server for the English dashboard.
- Lessons with a `check-on` field that names the input a mechanical check runs against.
- Security model documentation.

### Removed

- Everything specific to the original project: engine test runner and web export, art-generation
  integration and asset download bridge, visual review against reference images, the artist
  role, asset licence checks, the build server and its scheduled task.
