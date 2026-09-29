# Lessons

Lessons learned from past agent mistakes, matched against new findings to avoid repeating
them. See `scripts/lessons.ps1` for the reader/writer and the similarity check that decides
whether a new finding is the same mistake as an existing lesson.

## Active

### L-001 (2026-09-16)
- rule: Never write an acceptance command as a nested `powershell -Command "..."` line whose quoted text contains `$`.
- do: Write the quoted text as the acceptance command line itself, not wrapped in `powershell -Command "..."`, since the outer wrapper expands every `$name` before the inner shell parses it.
- source: seed
- check: `-Command\s+"[^"]*\$`
- check-on: acceptance
- hits: 0
- last-seen: 2026-09-16
- pinned: true

### L-002 (2026-09-16)
- rule: Never hardcode a fixed network port in a test that starts a local server.
- do: Let the operating system pick a free port (port 0) or accept a `-Port` parameter and pass it through; a fixed port collides with whatever else already listens on the host and fails for a reason no revision can fix.
- source: seed
- check: `(?i)(-Port\s+|localhost:|127\.0\.0\.1:)\d{2,5}\b`
- check-on: test-additions
- hits: 0
- last-seen: 2026-09-16
- pinned: true

### L-003 (2026-09-16)
- rule: Never edit or commit changes to a file outside the task's Owned paths, even when a fix seems to require it.
- do: Leave the out-of-scope file untouched. If the task's Result is still achieved without it, list it under `## Known limitations` as `left untouched (out of scope): <path> -- <why>` and finish; only if the Result cannot be achieved without editing it, write the `## Blocked` section with `reason: out-of-scope` naming the path.
- source: seed
- hits: 0
- last-seen: 2026-09-16
- pinned: true

### L-004 (2026-09-16)
- rule: Never scope owned_paths to only the new file being added when the change also requires editing the file that consumes or runs it.
- do: List every file the change will need in owned_paths, including the runner or caller a new test or module extends.
- source: seed
- hits: 0
- last-seen: 2026-09-16
- pinned: true

### L-005 (2026-09-16)
- rule: Never put a destructive or network command like Invoke-WebRequest, curl, git push, or git clean directly on an acceptance command line.
- do: Keep acceptance commands to read, build, or test operations only; the supervisor refuses those shapes outright.
- source: seed
- hits: 0
- last-seen: 2026-09-16
- pinned: true

### L-006 (2026-09-22)
- rule: Never put a whole-suite test runner on an acceptance command line.
- do: List the task's own tests as separate acceptance lines, one per command. The supervisor's test gate already runs the full suite before every review; a whole-suite acceptance command exceeds the per-command time budget as the suite grows, and the timeout reads as a host failure no author revision can fix.
- source: seed
- hits: 0
- last-seen: 2026-09-22
- pinned: true

### L-007 (2026-09-18)
- rule: Never reconstruct a merge by hand as an ordinary single-parent commit (copying files out of `origin/main` with `git cat-file`, `git checkout <ref> -- <path>` or the like): the reviewer then sees every file main changed as your change and the next rebase fails again.
- do: In a merge-conflict session run `git merge origin/main` (allowed there; origin/main is already fetched), resolve the conflicting hunks, `git add` them and `git commit` so the result is a real two-parent merge commit (`git log -1 --format=%P` shows two hashes).
- source: capability
- hits: 0
- last-seen: 2026-09-18
- pinned: true

### L-008 (2026-09-25)
- rule: A git write (`git add`, `git commit`, `git checkout`, a ref update) in a linked worktree can fail with an `index.lock` / `HEAD.lock` / `ORIG_HEAD.lock` error or `Permission denied` because another process (the supervisor's own acceptance run, another worktree's git) holds the lock at that instant.
- do: Wait a few seconds and retry the identical command, up to three times, before reporting it in `## Blocked`; the lock is transient. Never delete a lock file yourself.
- source: capability
- hits: 0
- last-seen: 2026-09-25
- pinned: true

## Retired
