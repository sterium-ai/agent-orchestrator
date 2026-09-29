# Case study: a Godot colony simulation built by the pipeline

The orchestrator was developed while it built **Deepholm, a deterministic colony simulation in
Godot 4**. The owner filed objectives as GitHub issues; the supervisor planned them, had Claude
Code, Codex or GitHub Copilot CLI implement each task in its own worktree, ran the project's
checks on the host, had a different provider review the result, and squash-merged the approved
commit. This page reports what that produced and where the pipeline struggled, using only figures
measured from the game repository's git history and files (commands at the end).

## At a glance

| Measure | Value |
| --- | --- |
| Pipeline-merged pull requests | **124** squash merges, 14–26 September 2026 (13 calendar days) |
| Busiest day | **25** merges on 18 September |
| Other squash-merged pull requests in the same history | 16 (integrator changes to the game and to the pipeline) |
| Headless test scripts (`test_*.gd`) | **93** |
| Individual `_check_` test cases in them | **810**, across 72 of those scripts |
| GDScript under version control | 67,095 lines, of which 42,155 are tests |
| Save-format migration steps (`save_migrations.gd`) | **24** consecutive steps, schema v1 to v25 |
| Architecture decision records | **46** files, 14 of them raising a core file-size budget |

The pipeline ran one task at a time on a single Windows host. Throughput therefore reflects
unattended, sequential work, not parallelism: the 124 merges are the output of a queue that kept
moving through nights and quota resets.

## What went well

**Independent review plus host-side evidence.** Every pipeline merge was made by the
supervisor, which merges only after an approval from a provider other than the task's author and
only when the pull request's head is the exact commit that reviewer read; before each review it
ran the gate that existed at the time (mechanical checks, the headless tests, and, once that
feature landed, the task's acceptance commands) on the host. The test suite grew with the
product: by the end, tests account for 63% of the tracked GDScript lines (42,155 of 67,095).

**Save compatibility was maintained through continuous change.** `save_migrations.gd` holds a
contiguous chain of 24 migration steps from schema v1 to v25, each guarded by a check that the
input really has the shape of the version it claims (24 `_is_schema_vN_state` functions). The
planner's rule that a task adding persisted state owns the serialization code, the schema and the
migration from the start is aimed at exactly this: a format change and its migration ship in the
same reviewed task.

**Architecture decisions were forced into the open.** The core-file budget in the pre-review gate
cannot be argued with by an author; raising a cap requires a decision record in the same change.
Fourteen of the 46 decision records carry `core-budget-increase` in their name, so growth of the
core files is explained in writing next to the code it allowed.

**The pipeline recovered its own dropped work.** When an agent's sandbox refused `git commit`,
or a session ended with changes still in the working tree, the supervisor committed them on the
author's behalf before validating and pushing (`chore(agent): commit work left uncommitted by
<provider>`). That recovery commit appears in 32 merges for Codex and 29 for Claude Code. In 19
pull requests it was the only commit: Codex had done the work but committed none of it, and
without the recovery those tasks would have been judged empty and rerun.

## Where the pipeline struggled

**Commit behaviour varied by provider and sandbox.** Nineteen Codex pull requests contained no
commit of Codex's own, and they kept appearing until the last days of the period. The recovery
made that harmless for the product, but it blurs who wrote what inside a pull request and means
the supervisor, not the author, chose the commit boundaries. The prompt contract
(`_agent-common.md`) accepts this explicitly -- "if your sandbox denies `git commit`, do not
fight it: leave the changes, say so in the handoff" -- because fighting a sandbox costs a session
while the recovery costs nothing.

**Budget raises became a per-round habit on hard tasks.** The budget rule worked as intended for
new features, but some difficult tasks raised the same cap in successive review rounds; the
decision-record file names show it ("rescue round 4", "rescue round 5", "trader visit round 2").
A decision per revision round is noise rather than design. Two countermeasures the pipeline
adopted are part of this release: task-sizing rules in the planner prompt (split any task naming
more than two new mechanisms) and automatic ownership of the budgets file and decisions folder, so
the cap can be discussed once, up front.

**Numbering collided.** Five decision-record numbers were used twice (012, 018, 019, 020 and
027). The likely cause is two branches, each correctly adding "the next ADR" from the `main` it
started from. Harmless, but a sign that anything allocated from shared state belongs to the
integrator or to merge time, not to an author.

**Commit trailers are not provenance.** 123 of the 124 merges carry a `Co-authored-by: Copilot`
trailer and 92 carry a Claude Sonnet 5 trailer, although the providers shared the work (the
supervisor's recovery commits alone name Codex in 32 merges): the game's `AGENTS.md` told every
agent to add the Copilot trailer. Eight merges carry a Claude Fable 5.1 trailer, the model
configured for expert recovery. The reliable record of who authored and who reviewed a task is
the supervisor's own issue comments and pull-request text, not git metadata; the template
`AGENTS.md` shipped here no longer asks for a trailer.

**Most of the orchestrator's complexity is scar tissue.** Many rules in
`docs/AGENT_SUPERVISOR.md` cite a specific task that lost rounds to the problem they fix: a
failure signature that ignores cosmetic commits, the free rescope for a `## Blocked` report, the
refusal to review a commit already rejected. Each rule is small; together they are the difference
between a demo and a queue that runs unattended for nearly two weeks.

## How the figures were measured

All commands are read-only and were run in a clone of the game repository.

```bash
# pipeline merges and their date range
git log --format='%ad|%s' --date=iso | grep -cE '\|(agent: |chore\(agent\): commit work left uncommitted)'
git log --format='%ad|%s' --date=short | grep -E '\|(agent: |chore\(agent\): commit work left uncommitted)' | cut -d'|' -f1 | sort | uniq -c

# test scripts, test cases and code size
git ls-files 'game/scripts/tests/*' | grep -c 'test_.*\.gd$'
git grep -c 'func _check_' -- 'game/scripts/tests/*.gd'
git ls-files 'game/*.gd' | xargs cat | wc -l

# migration steps and decision records
grep -c '^static func _migrate_v[0-9]*_to_v[0-9]*' game/scripts/core/persistence/save_migrations.gd
git ls-files docs/decisions | wc -l
git ls-files docs/decisions | grep -c budget-increase
git ls-files docs/decisions | sed -E 's#docs/decisions/([0-9]+)-.*#\1#' | sort | uniq -d

# recovery commits and trailers: count merges whose commit message contains the text
for h in $(git log --format=%H); do git log -1 --format=%B $h | grep -q 'commit work left uncommitted by codex' && echo $h; done | wc -l
for h in $(git log --format=%H); do git log -1 --format=%B $h | grep -qi '^co-authored-by: Claude Sonnet 5' && echo $h; done | wc -l
```

The 124 pipeline merges are the squash commits titled `agent: <task title> (#n)` (105) plus those
titled `chore(agent): commit work left uncommitted by codex (#n)` (19), the latter being pull
requests whose only commit was the supervisor's recovery commit.
