# Setting up the harness on your own project

> **In short:** a step-by-step path from an empty machine to a first task that is authored by
> one AI provider, reviewed by another, tested in CI and merged. Plan for about two hours.
> The architecture this implements is described in [README.md](README.md).

## Choose a control plane

| | Supervised parallel (recommended to start) | Unattended |
| --- | --- | --- |
| You | Open tasks, answer design questions, merge | File objectives; read results |
| Parallelism | Up to three tasks at once | One task at a time |
| Needs | [Orca](https://orca.dev) desktop app and CLI | A Windows host that stays on |
| Follow | This guide | The [quick start](../../README.md#quick-start) in the main README, after parts 1 to 3 below |

Both use the same task contracts, review rules and gates, so you can move between them.

**Tested configuration.** Windows 11, Windows PowerShell 5.1, Claude Code as author, Codex as
reviewer, GitHub Actions for CI. The reference scripts are PowerShell; on macOS or Linux the
same four steps apply but the scripts need porting.

## Part 1: Prerequisites

1. **Accounts.** Two AI coding providers with their command-line tools signed in (for example
   Claude Code and Codex). Two different vendors is the minimum for independent review. A GitHub
   account with a repository you can push to.
2. **Tools on `PATH`:** `git`, the GitHub CLI `gh` (run `gh auth login`), `claude`, `codex`.
3. **An install location without spaces or non-ASCII characters.** Install the agent CLIs to a
   plain path and put it on `PATH`:

   ```powershell
   npm install -g --prefix C:\dev\tools\npm @anthropic-ai/claude-code @openai/codex
   ```

   A user profile folder with accented characters, or a sandboxed app's virtualised `AppData`,
   will make terminals fail to find the tools.
4. **Pin the tools during work.** Disable agent CLI auto-update and update by hand between
   tasks; an update in the middle of a session can leave the binary unusable.
5. **Credentials stay out of the repository.** Sign in interactively; use environment variables
   for any API key. See [AGENT_CREDENTIALS.md](../AGENT_CREDENTIALS.md).

## Part 2: Prepare the repository

Copy the files in [templates/](templates/) into your repository and adapt them.

| Template | Put it at | What to change |
| --- | --- | --- |
| `AGENTS.md` | repository root | Your architecture rules and your test command. Keep it short; link to deeper documents instead of pasting them |
| `BACKLOG.md` | `docs/harness/BACKLOG.md` | Your first three tasks, each with Goal, Owned paths, Acceptance, Non-goals |
| `REVIEW.md` | `docs/harness/REVIEW.md` | Add the two or three rules specific to your product (for a game: determinism and save format; for a service: API compatibility and migrations) |
| `HANDOFF.md` | `docs/harness/handoffs/_template.md` | The exact final line your test runner prints |
| `claude-settings.json` | `.claude/settings.json` | The commands your project needs on the allowlist |

Then:

1. Add `.harness-review.md` to `.gitignore` (the reviewer's verdict is a scratch file).
2. Make one command run the **entire** test suite and print a single final line that states how
   many tests passed. Every gate keys off that line.
3. Add a CI workflow that runs that command on every pull request, with `paths-ignore` for
   documentation-only changes.
4. Protect `main`: require the CI check, require pull requests, allow squash merges only.
5. Commit and push.

## Part 3: The three scripts

The reference implementation is in
[sterium-ai/deepholm](https://github.com/sterium-ai/deepholm/tree/main/tools/orca):
`new-task.ps1`, `review.ps1`, `ship.ps1` and `setup.ps1`. Copy them to `tools/harness/` and
change the project-specific lines:

| Script | Project-specific lines |
| --- | --- |
| `new-task.ps1` | The backlog path; the launch prompt's test command and document names |
| `review.ps1` | The backlog and handoff paths; the pattern that counts your test files; the regular expression that reads the runner's final line; which paths count as documentation-only |
| `ship.ps1` | The name of your CI check in the closing message |
| `setup.ps1` | Replace the engine check with whatever your project needs installed |

What each one guarantees, so you can verify your port:

- **`new-task <id>`** refuses a task whose design is pending, creates a worktree named after the
  task, and launches the author with the task's own backlog entry inside the prompt.
- **`review`** exits without launching the reviewer when the branch is behind `main` in code or
  the handoff does not quote the runner's final line for the current test count. Otherwise it
  runs the reviewer read-only (`codex exec --sandbox read-only`), saves the verdict, and sends
  the author one line pointing at it.
- **`ship`** refuses to run on `main` or with uncommitted changes, pushes the branch and opens
  the pull request with the task's first commit as its title.

## Part 4: Install and connect Orca

1. Install Orca from [orca.dev](https://orca.dev). In the app, register its command-line tool
   under Settings, General, Orca CLI.
2. Verify from a new terminal: `orca status --json`.
3. Register the repository and set its base:

   ```powershell
   orca repo add --path C:\dev\<project> --json
   orca repo set-base-ref --repo "path:C:\dev\<project>" --ref origin/main --json
   ```

4. Restart Orca once after setting any environment variable your tests need, so its terminals
   inherit it.

## Part 5: Run the first task

```powershell
cd C:\dev\<project>
tools\harness\new-task.ps1 T1
```

1. **Author.** The agent reads `AGENTS.md`, does the task inside its worktree, runs the full
   suite, writes `docs/harness/handoffs/T1.md` and commits. It does not push.
2. **Review.** In a terminal inside the same worktree: `tools\harness\review.ps1`. If the verdict
   is `REQUEST_CHANGES`, the author fixes and commits; run the review again. One or two rounds is
   normal.
3. **Ship.** `tools\harness\ship.ps1`, wait for CI, squash-merge, delete the worktree.

A correct first run looks like this: a pull request whose only changed files are inside the
task's owned paths plus its handoff report, a verdict that begins `VERDICT: APPROVE`, and a green
CI run on the same commit the reviewer read.

## Part 6: Operating rules that keep it working

- **Concurrency.** At most three authors and two reviews at once on a 32 GB machine, and only
  one full test suite at a time. Put a named global mutex in your test runner so the limit
  enforces itself.
- **Audit the task before opening it** (ten minutes): the files exist, the acceptance is
  measurable today, nothing in flight touches the same files.
- **Size ceiling.** About 300 agent turns or four hours per task. Split anything larger before
  opening it.
- **Compaction.** Keep automatic compaction at roughly 120k tokens. Do not raise it for comfort.
- **Model tiering.** A cheaper model for mechanical sweeps and documentation; the strongest for
  design and core changes; higher reviewer effort for changes to core logic and persistence.
- **Serialize merges that touch shared core files.** Rebase each pull request on current `main`
  and let CI rerun before merging. Hand a conflicted rebase back to the task's author.
- **Never answer an agent's open question by typing over it.** Write the answer to a file and
  send one line pointing to it, or answer the menu with keys.
- **Before any shutdown,** ask each running author for a work-in-progress commit and a handoff
  note, push every branch, and record session identifiers so sessions can be resumed.
- **Protect real user data.** Anything that starts your product outside a real session must
  redirect its storage first and assert that it did.
- **Supervise on a slow clock.** Check every 45 minutes mid-task; every 20 minutes only while a
  review or CI run is in flight.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| A terminal cannot find `claude` or `codex` | Installed under a path the terminal cannot see | Install to a plain ASCII path on `PATH` (Part 1, step 3) |
| The orchestration CLI reports an unknown command when launching a task | Double quotes inside the prompt break argument passing in PowerShell 5.1 | Replace double quotes in the embedded task text with single quotes |
| Scripts print garbled characters or fail on accented paths | Console encoding | Save scripts as UTF-8 with a byte-order mark and set `[Console]::OutputEncoding` to UTF-8 |
| Sending text to an agent is rejected | The agent has a question open | Answer the menu, or cancel it and send a pointer to a file |
| The reviewer keeps asking for a rebase | The branch is behind `main` in code | Let the preflight catch it; rebase, rerun the suite, update the handoff |
| Tests fail on `main` as well | A tooling problem, not the task | Open a separate fix task; do not charge it to the author |
| The reviewer's provider has no quota | Quota wall | Wait for the reset, or run the review with a fresh session of the other vendor and record that it was less independent |
| A resumed agent prompts for every command | It came back in a more restrictive permission mode | Relaunch with the mode the repository settings expect |
| The machine becomes unresponsive | Too many agents or test suites at once | Apply the concurrency limits above |

## Going unattended

Once tasks pass through the cycle reliably, the supervisor in this repository can drive it
without a person: follow the [quick start](../../README.md#quick-start) and read the
[security model](../../README.md#security-model) first. Run it on an isolated machine with a
dedicated, low-privilege token and trusted issue authors only.

## Hardening (optional, not part of the tested configuration)

For stronger isolation than the agent CLIs' own permission systems, run authors inside a
runtime that enforces filesystem, process and network policy outside the agent process and
keeps credentials out of its reach. [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) is
one such runtime, for Linux, macOS and WSL 2. This harness has not been run on it; treat it as a
direction, and validate it on your own project before relying on it.
