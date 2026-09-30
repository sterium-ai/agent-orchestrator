# Agent credentials and unattended operation

> **In short:** how to sign in the AI tools and GitHub on the machine that runs the pipeline,
> and how to keep that machine safe when it runs on its own.

This repository does not store provider credentials. The supervisor only reads credentials
already available to the process environment or to the provider CLI's own local login store.
Read "Security model" in the README before running it unattended.

## One-time setup

Install and authenticate each provider on the machine that will run the supervisor:

```text
claude            # Claude Code, interactive login
codex login       # Codex CLI
copilot           # GitHub Copilot CLI (optional third provider)
gh auth login     # GitHub CLI
```

Use the provider's interactive login flow where possible. If an API-key flow is required, set
`ANTHROPIC_API_KEY` and/or `OPENAI_API_KEY` in the operating system's user or service-account
environment, not in any repository.

Verify without printing secrets:

```powershell
Get-Command claude, codex, copilot, gh
gh auth status
```

The supervisor refuses to start if GitHub authentication is unavailable. It reports missing
Claude or Codex executables and continues only when the configured task can be handled by an
installed provider; Copilot is optional.

Reserve Codex logins (used when the primary login is out of quota) are separate `CODEX_HOME`
folders under `codexAccountsDir` (default `%USERPROFILE%\.codex-accounts`), each created once
with `$env:CODEX_HOME="<folder>"; codex login`.

## Service-account guidance

For unattended operation, run the supervisor in an isolated VM or container under a dedicated
OS user with:

- access only to the clone and its worktree directory;
- a GitHub token limited to the one repository, with only the permissions the pipeline uses
  (issues, pull requests, contents; a fine-grained token is preferable to a classic one);
- provider usage limits and billing alerts;
- no personal browser profile, password store, cloud credentials or unrelated SSH keys;
- a process-level environment containing provider keys, if API keys are used.

Do not put keys in `.env`, issue bodies, prompts, logs, crash dumps, or commits. Rotate keys
immediately if they appear in any of those locations.

The dashboard reads Claude Code's local OAuth credentials only to call its usage endpoint; the
token is never written, logged or returned (see `docs/AGENT_SUPERVISOR.md`, "Plan and quota
fields").

## What must stay online

The repository contains the control plane, but provider subscriptions do not create an
always-running process by themselves. A machine or VM must stay online:

1. A persistent host runs `scripts/agent-supervisor.ps1` (as the scheduled task installed by
   `scripts/install-supervisor-task.ps1`).
2. GitHub issues and labels are the durable queue.
3. The supervisor claims one issue at a time, creates an isolated worktree, runs the selected
   provider CLI, validates the branch, and pushes it.
4. A different provider reviews it; the supervisor merges exactly the approved commit.

Use GitHub Actions for validation and scheduled health checks, not as the primary place to run
paid agent sessions.
