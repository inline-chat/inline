# Server testing

A passing test should establish an observable contract: a result, a persisted
invariant, a permission boundary, or a failure/recovery outcome. Test counts and
line coverage are diagnostic tools, not substitutes for those contracts.

## Run tests

Use Bun 1.4.0 (the CI version). From the repository root, first run
`bun install --frozen-lockfile`. Then, from `server/`:

| Command | Purpose |
| --- | --- |
| `bun run test:unit` | Bun tests without the PostgreSQL lifecycle; no database configuration needed |
| `bun run test:effect` | Effect tests on Node/Vitest, then Bun-specific Effect integration tests; the latter may need PostgreSQL |
| `bun run test:postgres` | All database-backed tests, including colocated tests outside `__tests__` |
| `bun run test:repair` | Recovery strategy, lifecycle/permission regressions and real PostgreSQL discovery query budgets; see [discovery design](docs/recovery-discovery.md) |
| `bun run test:backend` | Hot-path behavior and query budgets, plus replay, transaction and concurrency contracts |
| `bun run bench:backend` | Verified backend benchmark scenarios and optional database latency injection; see [BENCHMARKING.md](BENCHMARKING.md) |
| `bun run test:preview` | URL preview workspace tests, including network boundaries |
| `bun run test` | Discovery/lint guard, all Bun tests, Effect tests, and preview tests |
| `bun run test:list` | Exact inventory, runner ownership and database requirement |
| `bun run test:check` | Discovery and accidental focused-test checks |

For database tests, explicitly set `TEST_DATABASE_URL` to a **local PostgreSQL**
server using a role with `CREATEDB` (CI uses PostgreSQL 15):

```sh
TEST_DATABASE_URL=postgres://localhost:5432/postgres bun run test:postgres
```

The database named in the URL is a connection source, not a reset target. The
runner creates a randomly named disposable template, applies the real migrations
once, closes it, and clones a separate database for each test file. Only the
harness's own databases are dropped. It rejects remote hosts and connection
query overrides. It neither truncates nor migrates your configured database.

```sh
# A file or path filter; a typo that matches nothing fails.
bun run test:bun src/__tests__/flows/messageIntegrity.test.ts

# Debug serially without weakening file isolation.
bun run test:bun --jobs 1 src/__tests__/flows

# Reproduce order sensitivity and repeat every test file without hiding failures.
bun run test:bun src/__tests__/flows -- --randomize --seed=42 --rerun-each=5

# Check the full migration path independently of template cloning.
bun run test:postgres --no-template --jobs 1 database.lifecycle

# Investigate timing or coverage of a focused area.
bun run test:bun src/utils -- --coverage
bun run test:bun --report-dir /tmp/inline-test-reports
```

Run commands from `server/`; the runner also resolves its own root when invoked
via `bun run --cwd server`. Do not run raw `bun test` over the whole server:
Effect tests have a different owner and legacy module mocks require isolation.
A directly invoked single Bun file is useful for debugging, but use the canonical
runner for acceptance.

## Isolation and speed

The runner uses Bun's native isolated workers, with at most two workers by
default (bounded by available CPU cores). `--jobs 1..8` controls the file worker
count. Tests inside a file remain serial because they share a database, caches,
module mocks and globals. Exercise **application** concurrency with explicitly
coordinated promises inside one test. Do not add `test.concurrent` to a suite that
uses shared fixtures or `cleanDatabase`.

Worker processes are recycled every `6 × jobs` files to bound the memory retained
by a long sequence of isolated VMs. The migrated template remains available across
batches. A failing batch fails the overall run; later batches still execute, and
no file is retried. JUnit, timings and optional coverage output remain separate
per batch, with a fresh report directory per invocation so older runs cannot
contaminate the timing data. For a single coverage report, use a focused file selection.

`setupTestLifecycle()` installs database setup, per-test cleanup, and teardown.
Tests are not wrapped in a hidden rollback transaction: production code can use
multiple connections and commit for real, including concurrency and after-commit
behavior. Cleanup preserves migration history and sequence high-water marks, clears the
access cache, and verifies the connected database is owned by the lifecycle.
Setup is reference-counted for existing nested suites. Errors in setup, migration,
reset or teardown fail the run. New suites should prefer one lifecycle per file:

```ts
import { expect, test } from "bun:test"
import { setupTestLifecycle, testUtils } from "./setup" // adjust relative path
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { getChatHistory } from "@in/server/functions/messages.getChatHistory"

setupTestLifecycle()

test("the recipient can read a sent message", async () => {
  const sender = await testUtils.createUser("sender@example.test")
  const recipient = await testUtils.createUser("recipient@example.test")
  const chat = await testUtils.createPrivateChat(sender, recipient)
  if (!chat) throw new Error("Expected private chat")
  const peerId = { type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chat.id) } } }
  await sendMessage({ peerId, message: "Hello" }, testUtils.functionContext({ userId: sender.id }))
  const history = await getChatHistory({ peerId }, testUtils.functionContext({ userId: recipient.id }))
  expect(history.messages.map(message => message.message)).toEqual(["Hello"])
})
```

The canonical runners inherit only basic runtime environment variables. Service
credentials and rollout flags do not carry over from a developer's shell. Tests
use fixed dummy credentials, UTC, and disabled telemetry. Configure the feature
being tested **inside that test**, then restore it. The unit lane has a deliberately
unreachable database URL so accidentally querying a database fails.
This also applies to unit files within the full suite: batches are separated by
their database requirement before assigning the child process environment.

A preload blocks non-loopback `fetch` requests and fails the test even if code
catches the resulting error. Local fetch cannot follow redirects. Provider tests
should inject a fake HTTP implementation or a local server and assert request and
response semantics. This guard is not an OS network sandbox: code using raw
sockets, node HTTP, or an SDK-specific transport must use an explicit fake too.
Live provider checks belong in separately authorized smoke tests.

File isolation protects files from one another; it does not replace good cleanup
within a file. Restore spies, environment changes and global substitutions, stop
servers, settle launched work, and release deferred promises in `finally` blocks.
Use `Promise.allSettled` when testing concurrent failures so no losing request is
still writing while the next test resets the database.
For fire-and-forget work, `src/__tests__/background.ts` can observe real async
functions through spies and drain their complete job chain in `afterEach`.
The subthread tests use this to await graph, parent-card and title work after
the visible result has committed. Draining also surfaces caught job failures.

## What to test

| Risk | Evidence the test should establish |
| --- | --- |
| Input and domain logic | Boundaries, malformed input, Unicode/offsets, empty and maximum values, stable normalization; use tables of cases |
| Authorization | Owner/member/guest/outsider, wrong tenant, revoked access, resource ownership; assert the expected error **and no persisted or emitted side effects** |
| Database models | Real constraints, joins, transaction rollback, uniqueness, cascades, encryption round trips, sequence/cursor invariants |
| Stateful flows | Compose multiple real operations: create/send/read/edit/delete, grant/revoke/retry, login/redeem/replay; inspect both response and durable replay |
| Concurrency | Duplicate requests, competing writers, CAS/version conflicts, lock ordering; coordinate actual overlap instead of guessing with sleeps |
| Failure handling | Fail after an earlier write, interrupt a provider, expire a lease, retry after a commit; distinguish rollback from committed-but-delivery-failed |
| HTTP and realtime adapters | Exercise the actual route/dispatcher for validation, authentication, error/status mapping and serialization; use real local sockets for socket behavior |
| Effect orchestration | Real layers, cancellation, retry schedules, scope finalizers and fibers with `@effect/vitest` and `TestClock` |
| Migrations and rollout | Apply real migrations; test existing-row compatibility and invariants separately from an empty-schema bootstrap |

Useful examples:

- `src/__tests__/flows/messageIntegrity.test.ts`: real message lifecycle,
  concurrent idempotency, unauthorized no-op state, forced database rollback,
  and a deterministic lock regression.
- `src/__tests__/database.lifecycle.test.ts`: failed and overlapping setup,
  cleanup ownership, environment restoration, migration history and teardown errors.
- `src/__tests__/modules/providerAuthRedemption.test.ts`: proof-key and ticket
  rejection without session changes, concurrent redemption, and atomic rollback
  of ticket consumption plus device-session replacement.
- `src/__tests__/modules/updateDiscoveryBarrier.test.ts`: durable discovery ordering.
- `src/__tests__/functions/messages.acknowledgeMessages.test.ts`: revisions,
  retries, deleted targets and durable replay.
- `src/core/http/realtimeV3Host.test.ts`: local transport behavior.

Mock external side effects at their boundary. A test of a function that replaces
its authorization, repository, transaction and implementation with mocks does
not prove the flow. Keep narrow adapter tests, but pair important paths with a
real-database test. Assert meaningful state, not merely that a mock was called.
Do not assert nondeterministic ordering unless ordering is the contract.

When fixing a regression, demonstrate that the targeted test fails before the
fix and passes after it. Prefer explicit barriers, virtual clocks and injected
faults. Avoid unconditional sleeps, swallowed exceptions, silent conditional
returns, focused tests, and retries that turn intermittent failures green.
Any skipped test needs an explanation and a tracked follow-up.

## Discovery, CI and remaining coverage work

Every `.test.ts`, `.spec.ts`, `.test.tsx` or `.spec.tsx` under `src/`, `scripts/`,
and the URL preview workspace must import exactly one runner. Discovery uses
Bun's TypeScript import scanner, so comments do not affect ownership. Vitest
consumes the same inventory; a new Vitest test outside `core/` or without an
`.effect` suffix is still discovered. Bun-specific Effect tests use
`.effect.bun.test.ts`. Test fixture directories are not test roots.

Database lane detection follows local static imports/reexports to the lifecycle.
Use static lifecycle imports, not computed dynamic imports. The unit lane is a
no-database execution lane; it also contains component and local-socket tests,
not exclusively pure functions.

CI checks discovery, focused tests, types, lint, all test lanes, migration startup,
route/OpenAPI manifests, and production artifact smoke tests. JUnit and per-file
Bun timings are uploaded even on failure. These reports identify slow files and
failed tests; they do not retry failures. Seeded random-order runs are available
for isolation investigations. Keep the regular suite fast and deterministic.

Coverage is useful to locate untested branches; a percentage alone cannot prove
that authorization, concurrency or recovery is correct. There is no newly imposed
blanket threshold or claim that every server behavior is covered. Future coverage
should prioritize multi-tenant permission matrices, revoke/rejoin flows, provider
callback races, cross-layer error/cancellation paths, and upgrade fixtures from
older database states. Existing focused tests in these areas remain useful;
expand them when changing the corresponding contract.

Upstream references: [Bun file isolation and parallelism](https://bun.com/docs/test/parallel),
[PostgreSQL template databases](https://www.postgresql.org/docs/15/manage-ag-templatedbs.html),
and [PostgreSQL row-lock compatibility](https://www.postgresql.org/docs/15/explicit-locking.html).
