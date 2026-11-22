# Data tasks

Data tasks change production data that a schema migration shouldn't. Like
migrations, they ship in a PR and apply on their own: nobody runs a command.
The code is in `src/modules/dataTasks`. The ledger is in the `data_task_items`
and `data_task_runs` tables.

## Migration or data task?

Use a **SQL migration** for a small, deterministic data change the schema
needs to be correct in every environment: backfilling a new `NOT NULL` column,
repairing a counter. It runs with the DDL, in one transaction, before the API
starts.

Use a **data task** when any of these is true:

- It acts on a cohort chosen by a product or policy decision, not by the schema.
- It must go through domain code: grants, settings, sync updates, encryption.
  The release job only has a database credential; the worker has the rest.
- It is large or slow (migrations share one transaction and a 30s statement budget).
- It may need to be undone item by item.

Migration 0173 (opening old bots to everyone) should have been a data task.
Its limits would have shown that 212 of the 222 bots it opened were never used
by anyone but their owner, and its updates would have reached the apps.

## How it runs

The worker process (`INLINE_PROCESS_ROLE=all`) runs every registered task
that hasn't completed, 2 minutes after boot and then hourly. Tasks run in
registry order; one that doesn't complete holds back the ones after it.

1. **Lease.** A `running` row in `data_task_runs` keeps one run per task across
   processes. It is renewed as the run goes and taken over once it is 2 minutes stale.
2. **Plan.** `select` runs, merged with the items the ledger already holds, and is hashed.
3. **Limits.** If the plan exceeds `limits` (total items, items per tier, unknown
   tiers) or fails `check`, the run is **blocked**: nothing is applied.
4. **Items.** Each item commits on its own transaction, together with its ledger row:
   `apply` locks and re-checks it, and `verify` checks the result before commit.
   A failed `verify` rolls the item back and **fails** the run.
   An item that no longer qualifies is skipped; more than `maxSkips` blocks the run.
5. **Completion.** A `completed` run ends the task for good, like a migration. Rows
   that match later are not picked up.

Blocked and failed runs log as errors, which alert through Sentry, and are
retried hourly. A run paused by shutdown or its 10-minute budget resumes on
the next tick. Set `DATA_TASKS_PAUSED=1` on the worker to stop all runs without a deploy.

Fresh and development databases run the same tasks; an empty cohort completes at once.

## Writing one

Add `src/modules/dataTasks/tasks/<date>-<slug>.ts` and register it in
`registry.ts`. Review it like a migration:

- `select(query)` is read-only and returns items: `key`, `tier`, optional `noop`,
  and a `plan` (IDs and flags only, never content). Use fixed cutoffs, not `now()`.
- `limits` is required. Set it just above what a read-only dry run of `select`
  against production returns, and note that dry run in the task's doc comment.
- `check(plan)` adds whole-plan invariants, such as caps on the grants it creates.
- `apply(tx, item)` changes one item through domain helpers that take the
  transaction, and returns `before` and `after`. Throw `DataTaskSkip` if the item
  no longer qualifies, such as when the owner changed it since.
- `verify(tx, item)` returns a reason if the applied item is wrong.
- `revert(tx, entry)` restores `before`, skipping items changed since.

Each task gets a Postgres test with a fixture per tier and a case per limit.
`2026-11-21-close-grandfathered-bots.test.ts` is the reference.

## Inspecting and emergencies

From a shell with the worker's environment:

```sh
bun server/dist/data-task.js list                        # tasks and whether each completed
bun server/dist/data-task.js plan <task> --items         # dry run, with any limit violation
bun server/dist/data-task.js status <task>               # ledger counts and the latest run
bun server/dist/data-task.js revert <task> --database <name> --backup-verified [--key bot:42]
```

There is no manual apply. `run` does one automatic pass, for local development.
An item with a ledger row is never applied again, even after a revert.
