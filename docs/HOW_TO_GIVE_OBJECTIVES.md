# How to get things built without touching the code

You describe *what* you want. The agents decide *how*, build it, check each other's work,
and merge it. You read the results in the same place you asked for them.

## 1. Ask for something

1. Open a new issue in the target repository.
2. **Title:** the objective in one sentence, e.g. *"Users can export their data as CSV"*.
3. **Body (optional but helpful):** what it should do, what must not change, anything you
   already know you want. Plain language is fine. Bullet points are fine.
4. Under **Labels**, choose `objective`.
5. Click **Submit new issue**.

That is all. Within a couple of poll cycles the supervisor comments on your issue with a plan
and creates one issue per task. You can watch progress in the comments of your objective
issue; each task issue shows who is working on it and the review verdict.

If the supervisor runs with a trusted-authors list (`acceptance.trustedAuthors`), only
objectives written and last edited by people on that list are planned; anything else is moved to
`objective-failed` with an explanation.

Good objectives are one feature or one improvement. "Add CSV export" is good. "Build the whole
product" is too big; the planner will try, but the tasks will be vague and the reviews harsh.
File several objectives instead; they are processed in order, one task at a time.

## 2. Read the results

- **Your objective issue** gets a comment when the plan is ready, when each task merges,
  when something fails, and a final **Done** comment when everything is on `main`.
- **Task issues** carry the full trail: the contract, "started", the pull request link, the
  review verdict, and "merged".
- **Pull requests** hold the code and the reviewer's notes, if you are curious.

Labels tell you the state at a glance:

| Label | Meaning |
| --- | --- |
| `objective` | Waiting to be planned |
| `objective-planned` | Tasks created; work in progress |
| `objective-done` | Everything merged |
| `objective-failed` | The planner could not make sense of it (or its author is not trusted); make it more specific and re-add `objective` |
| `agent-blocked` | Waiting for another task to finish first |
| `agent-ready` | Queued |
| `agent-in-progress` | An agent is coding |
| `agent-review` | A different agent is reviewing |
| `agent-done` | Merged |
| `agent-failed` | Needs attention; read the last comment |

## 3. When something fails

Read the last supervisor comment on the failed task; it says why in plain words and which label
resumes it. Usually one of these:

- **The repair step needs a decision.** The comment explains what must be decided. Edit the
  task issue to clarify, then follow the retry advice in the comment.
- **An open pull request exists.** Remove `agent-failed` and add `agent-review`: the commits are
  kept and the checks run again from them.
- **No pull request exists.** Remove `agent-failed` and add `agent-ready`: the task is
  implemented again from a fresh `main`.

## 4. Behind the scenes (for the curious)

`scripts/agent-supervisor.ps1` runs on an always-on Windows host as a scheduled task. Every poll
cycle it looks at GitHub: it plans new objectives, gives each task to the provider the planner
chose in an isolated git worktree, runs the project's tests and the task's acceptance commands
on the host, has a *different* provider review the result read-only, and merges exactly the
commit that was approved. Rules the agents follow live in the target repository's `AGENTS.md`
and `docs/decisions/`. The prompts they receive are in `docs/agent-prompts/`. Nothing merges
without an independent approval; nothing is retried forever; every decision is a comment you
can read.

Useful commands (from the target repository's clone, PowerShell; `<tool>` is where this
orchestrator lives):

```powershell
<tool>\scripts\agent-supervisor.ps1 -ConfigPath .\agent-orchestrator.json -DryRun -Once   # show the queue without doing anything
Get-Content .agent-state\supervisor.log -Tail 40                                        # what the supervisor did recently
Get-ScheduledTask AgentSupervisor                                                       # is the always-on task registered/running
<tool>\scripts\serve-dashboard.ps1                                                      # the dashboard on http://localhost:8765/
```
