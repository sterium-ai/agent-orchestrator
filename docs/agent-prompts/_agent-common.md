- Edit only the files under `Owned paths` in the task. Files a build or import tool generates
  next to files you add are fine. Never touch the paths the project marks as protected in
  `AGENTS.md`.
- Commit your work in small atomic commits with conventional commit messages. Do not push;
  the supervisor pushes and opens the pull request. Do not create branches. If your sandbox
  denies `git commit`, do not fight it: leave the changes in the working tree, say so in the
  handoff, and the supervisor will commit them for you.
- If you cannot finish -- the task, or a finding in a revision round, needs a file outside
  `Owned paths`; something on the host is in the way (a port already in use, a locked file, a
  missing tool); or an acceptance command in the task body can never pass as written -- do
  not work around it and do not commit a revision that changes nothing. Say so in the handoff
  with a section of exactly this shape, and the supervisor stops the task for a person instead
  of relaunching you against the same wall:

  ```
  ## Blocked
  reason: environment | task-body | out-of-scope
  <one line: what is in the way, with the path, port or command named>
  ```

  `environment` = the host (fixable only on the machine); `task-body` = the issue text itself;
  `out-of-scope` = a file outside your owned paths (name the paths). Not having a browser
  from your sandbox is NOT `environment`. If a project tool is not found in your sandbox,
  quote the error under `## Known limitations` and finish anyway (the supervisor runs the
  acceptance commands and the test gate on the host): that is a host problem, not a reason to
  stop. An acceptance item only a human can do (look at the running product, judge a feel,
  quote a measured time) is `task-body` at most -- and usually not even that: finish the code,
  make the commands pass, and list the item under `## Known limitations` as
  `owner verification after merge: ...`. That is far cheaper than a review round that cannot
  change anything. Use it only when it is true: a `Blocked` you could have fixed costs the
  owner's time instead of yours.

  `## Blocked` means the task's Result is NOT achieved. A file outside your owned paths that
  you deliberately left alone because the Result holds without it (a doc another task owns, a
  cosmetic follow-up) is not a block: list it under `## Known limitations` as
  `left untouched (out of scope): <path> -- <why>` and finish. Writing `## Blocked` for a task
  that is actually done stops it for a repair round that changes nothing.

## Before editing: feasibility and failure cases

Use the current checkout, not version numbers or module descriptions copied from an older
task. In the handoff record a short `## Feasibility` section: the existing extension point,
affected contracts/tests, and helper files needed within Owned paths. If behavior needs new
persistent state, include serialization, validation, migration and continuation tests in the
same slice; a later task cannot justify breaking stored data now. If scope or Non-goals forbid
the necessary change, report `## Blocked` with `task-body` before coding around it.

For stateful behavior, record a compact transition table (state, trigger, next state,
persisted data), including cancellation, interruption, destruction and reload where relevant.
Identify execution state through the existing mechanism; do not infer it from values that can
change independently. Do not invent a second mechanism to fit a file list.

For a bug correction, first reproduce the reported scenario with a targeted test or command.
Record the failing result, then the passing result after the fix. If execution is unavailable,
report that limitation honestly. Exercise the real interaction; a fixture that avoids the
failing state is not proof. Keep existing assertions and thresholds. Fix regressions in
production behavior; change a contract only when the task explicitly authorizes that product
change. A decision record written by the author is not permission to waive acceptance criteria.

## Handoff (mandatory)

Write `.agent-state/HANDOFF.md` in the worktree (create the `.agent-state` folder if it
does not exist; it is git-ignored, so do NOT commit it and do not put it anywhere else).
It must contain, under these exact headings: `## Branch`, `## Owned paths touched`,
`## Contract impact`, `## Validation` (each acceptance check and how you satisfied it; for
commands, write "run by the supervisor on the host" unless you were actually able to run
it, in which case quote the real output), `## Known limitations`, `## Next action`. The supervisor reads it
from there, shows it to the reviewer and pastes it into the pull request.

Keep it to facts, under 40 lines: what changed, where, what remains. Do not explain what your
sandbox could not run or how you tried; the reviewer already knows, and the supervisor cuts the
handoff at 3500 characters before the reviewer sees it.
