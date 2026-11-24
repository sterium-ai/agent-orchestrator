# How agents contribute to this repository

> Keep this file short. It is a map: rules that always apply, and where to read more.

## The project

<!-- Two or three sentences: what the product is, the main language, where the code lives. -->

## Rules that always apply

- **One task, one branch, one pull request.** Take exactly one task by id from
  `docs/harness/BACKLOG.md`. Read its whole entry before touching a file. If it is ambiguous,
  ask; do not guess.
- **Stay inside the task's owned paths** (plus their tests and documents). Anything else needs
  the owner's recorded approval.
- **Contracts before code.** Check `docs/decisions/` before proposing architecture. A change to
  a public data shape updates its contract, schema, example and test in the same change.
- **Never weaken verification.** Disabling, skipping or loosening a test, or raising a size
  budget to make a check pass, is a defect in itself.
- **Never touch real user data.** Anything that starts the product outside a real session
  redirects its storage first and asserts that it did.
- **You cannot push or merge.** Commit when done; the integrator ships.

## Working method

1. Run the full suite first to record the baseline: `<TEST COMMAND>`.
2. Work in small packages. Use sub-agents to explore code; they return summaries, not files.
   Do not paste long files or full test output into the conversation; filter it.
3. Budget: about 300 turns. If the task does not fit, deliver what is closed and note the rest.
4. Before handing off, read `docs/harness/REVIEW.md`: it is the reviewer's script, so everything
   it checks should already be true.
5. Write the handoff report at `docs/harness/handoffs/<id>.md` from the template, update the
   task's status row in the backlog, and commit.

## Where to read more

<!-- Links only: architecture documents, decision records, contracts. -->
