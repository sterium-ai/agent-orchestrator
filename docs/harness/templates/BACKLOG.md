# Backlog

> Tasks are taken from here by id, in order. An entry is a contract: the author may change only
> its owned paths, and the reviewer checks its acceptance lines one by one.

## Status

| Id | Title | Status |
| --- | --- | --- |
| T1 | <title> | todo |

Status values: `todo`, `in progress`, `in review`, `merged`, `blocked`.

## Entries

### T1 — <imperative title under 80 characters> · `todo`

- **Goal:** what is true when this is done, as a user or a caller observes it.
- **Owned paths:** every file or folder the change will foreseeably touch, including
  persistence, schemas and the tests that assert on them.
- **Acceptance:** three to six checks a machine or a reader can verify. Name the real
  end-to-end trigger. One command per line, each bounded in time.
- **Non-goals:** what must not change.
- **Design:** *pending* until the owner has answered the open product questions. A feature task
  is not opened while this says pending.
- **Parallel-safe:** yes or no, and with which in-flight tasks it would collide.

<!--
Before opening any task, check it against the assumption register:
1 behaviour it relies on exists  2 contract terms quoted exactly  3 ownership complete
4 numbers and paths measured     5 acceptance goes through the real trigger
6 no pipeline side effect blamed on the author  7 atomic changes kept in one task
-->
