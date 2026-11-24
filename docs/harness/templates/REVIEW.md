# Review guide

> What the reviewer (a different provider from the author) checks on every change, and the
> exact shape of its verdict. The author reads this before handing off.

The reviewer compares the branch with `main`, reads the task entry in the backlog, and answers
one question: **is this change safe to merge as it is?** It never edits code.

## Always

1. **Scope.** Only the task's owned paths (plus their tests and documents) changed. Anything
   else is blocking, even if the extra change is good.
2. **Tests are real.** No test deleted, skipped, commented out, renamed out of the runner's
   pattern, or weakened. Compare the list of test files and assertion sites with `main`.
3. **Suite ran.** The handoff report quotes the runner's final line for the branch head, with a
   test count no smaller than `main`.
4. **Architecture rules** from `AGENTS.md` hold.
5. **Budgets and lints** pass, and no cap was raised without a decision record.
6. **Data formats.** A changed persisted or public shape declares its version bump, migration
   and fixture; otherwise it is blocking.
7. **Report honesty.** Every claim in the handoff is checkable in the diff or the test output.
8. **User data untouched.** Nothing in the diff reads or writes real user data.

<!-- Add the two or three checks specific to your product here. -->

## Verdict format

Write exactly this, nothing before it:

```
VERDICT: APPROVE | REQUEST_CHANGES

Blocking:
- <file:line> — <what is wrong> — <what would fix it>
(or "none")

Non-blocking:
- <file:line> — <suggestion>
(or "none")

Checked:
- scope: <ok | files outside owned paths: ...>
- tests: <N files on main, N on branch; weakened: none | ...>
- suite line quoted in report: <yes | no>
- budgets: <ok | raised: ...>
- data formats: <unchanged | bump declared with migration and fixture | CHANGED WITHOUT BUMP>
```

`REQUEST_CHANGES` whenever the Blocking list is not empty. One line per finding, with a file and
a line number.
