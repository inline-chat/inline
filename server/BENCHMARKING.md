# Backend performance contracts

Use `test:backend` to protect behavior and database command budgets. Use
`bench:backend` to measure changes. Both execute the same real PostgreSQL
scenarios, with real encryption, authorization, transactions and replay encoding.
The benchmark runner accepts a sample only after its behavioral assertions pass.

## Run

Install the locked dependencies with `bun install --frozen-lockfile`, then run
these commands from `server/`, using Bun 1.4.0 and a local PostgreSQL role with
`CREATEDB`. The existing test lifecycle creates and disposes its own migrated
database; the database in the provisioning URL is never reset or migrated.

```sh
export TEST_DATABASE_URL=postgres://localhost:5432/postgres

# Correctness, query budgets, allocator/replay/rollback/concurrency contracts.
bun run test:backend

# Inventory without a database.
bun run bench:backend --list

# Representative paths; defaults to 3 warmups, 20 samples, no added delay.
bun run bench:backend --output .test-results/before.json

# Same command after a change. Both reports must use matching settings.
bun run bench:backend --compare .test-results/before.json --output .test-results/after.json

# Explore sensitivity to additional DB transport latency on one path.
bun run bench:backend --scenario send.dm.open --rtt 0,3,5

# Check the entire benchmark workflow quickly; this is not a tail-latency study.
bun run bench:backend --all --samples 1 --warmup 1
```

Repeat `--scenario ID` to select several paths. `--all` includes the expensive
100-recipient reply and update fanout cases. Delayed, repeated runs of all paths
can take several minutes. Output paths must be new JSON files: baselines are
never overwritten. Unknown selections, invalid arguments, failed assertions,
background failures, failed cleanup and incomplete runs exit unsuccessfully.
Interrupted worker artifacts are candidates, not accepted comparison baselines.

Run timing experiments alone, on the same otherwise idle machine, database
version and power configuration. Avoid concurrent builds and tests. Repeat A/B
measurements before claiming a small improvement. Keep reports with the change;
reports contain the commit, dirty flag and a SHA-256 digest of `server/`, shared
`packages/` and the lockfile, including uncommitted files (excluding ignored and
environment files). Changing
those sources during a benchmark invalidates the run.

## What is measured

Each iteration follows this sequence:

1. Drain previous jobs, reset the owned database, construct a fresh fixture, and
   clear authorization/session activity caches. Connection pools stay alive.
2. Enable the requested loopback delay and the driver's query observer.
3. Invoke the real operation and record its return time.
4. Await the registered background job chain and record the settled time.
5. Stop measuring, disable delay, verify the result and durable state, then
   enforce the reviewed command budget. Warmups follow the same checks.

| Field | Meaning |
| --- | --- |
| `operationMs` | Monotonic wall time until the function returns |
| `settledMs` | Time through completion of registered detached work |
| `sql.commands` | Application submissions observed by Postgres.js, including `BEGIN`, `COMMIT`, rollback and lock queries |
| `sql.catalogCommands` | Driver array-type discovery, separately reported because it depends on connection warmth |
| `sql.shapes` | Counts by command kind and scrubbed statement hash; no SQL text or bind values |
| `commandsBeforeReturn` | Commands submitted by return time; background work can overlap, so this is **not** a foreground-only count |
| `wire.exchangeBoundaries` | Frontend `Query`, `Flush`, and `Sync` frames observed at the proxy |
| `calibrationMs` | Ten real `SELECT 1` timings at the requested delay, outside the operation samples |

One driver submission can contain several SQL statements, so `sql.commands` is
not a SQL parser's statement count. A transaction does not make its statements
one network exchange. Extended queries can require Describe/Flush followed by
Bind/Execute/Sync. Conversely, several connections can overlap exchanges. Neither
SQL count nor exchange count multiplied by RTT equals critical-path latency.
Use the recorded times and frame counts together.

The proxy forwards plaintext only between loopback sockets. It adds half the
requested delay in each direction and counts frame types and bytes without
decoding SQL or bind payloads. It is an experiment in transport-delay sensitivity,
not a reproduction of PlanetScale routing, TLS, network bandwidth, packet loss,
server CPU or connection-pool behavior. Stream chunking, timers and backpressure
affect actual delay, so compare calibration distributions too. Wire counts
include any catalog discovery inside a sample.

Benchmarks use one active operation, cold application caches, warmup iterations
and the production pool configuration. Fixtures and verification queries are
excluded. Samples, median, minimum/maximum and p95 (only with at least 20 samples)
are available through `summarize`; reports retain raw samples. A 20-sample p95 is
still a rough estimate, not a production SLO. These are module/function
measurements, not authenticated HTTP/WebSocket end-to-end latency or maximum
server throughput. Saturation, open-loop load, pool queueing, production data
cardinality and multi-server delivery need separate experiments.

## Coverage and budgets

The initial catalog has 24 scenarios:

- DM send with open/closed dialogs and an idempotent retry.
- Public-thread and reply-thread sends with 1, 10 and 100 recipients.
- Chat lists with 1, 10 and 100 DMs, and a 50-message history page.
- Empty/nonempty chat replay and a fresh discovery checkpoint.
- User update batches and unchanged dialog batches at 1, 10 and 100 users.
- Read-position advancement and its unchanged case.

Fixtures are synthetic human-only conversations, silent sends, named threads,
plain text and no Bot streams or attachments. Real graph/title/parent jobs are
observed with pass-through spies. The Bot projector's no-stream branch is drained
through its two reads. New Bot, media, preview, generated-title or notification
scenarios must register their full job lifetimes before claiming complete costs.
Do not disable domain jobs to make a path pass its budget.

`catalog.ts` holds reviewed maximum command counts. They represent current costs,
including costly linear fanout; they are not desired targets. Lower them with a
proven optimization. Do not automatically regenerate budgets or loosen one to
hide a regression. The 1/10/100 cases expose scaling: current public sends cost
`32 + recipients`, reply sends `66 + 7 × recipients`, and user update batches
`2 + 4 × updates` for these fixtures. Chat-list queries remain constant at 11
while result volume grows. These are local fixture observations, not production
traffic statistics.

`test:backend` also selects the existing send, chat-list, history, message integrity,
update discovery, user allocator, replay and dialog contracts. They cover authorization without
side effects, same-message retries, ordering, encryption, journal rollback,
discovery fences, replay gaps and stale counters. New batch tests cover duplicate
owners and two independent database clients with overlapping owner sets. This
proves database coordination across connections; it does not qualify cross-server
caches, delivery, worker leadership or authorization invalidation.

All deterministic tests are discovered by the normal Bun/CI lane. Wall-clock
benchmark results are intentionally not pass/fail CI thresholds. The manual
worker under `bench/` is typechecked and linted but runs only through the benchmark
launcher. No new benchmark dependency or production code is required.

## Extend the foundation

Add a catalog entry and a corresponding `prepareScenario` branch. Preparation
returns `run()` and `verify()`; store the result in the closure, and assert both
response semantics and database state in `verify()`. Include failure, permission,
idempotency and contention contracts in ordinary tests where applicable. Prefer
fixtures at multiple cardinalities and meaningful payload sizes over dozens of
slightly different happy paths. Bump `scenarioVersion` when fixture or measurement
semantics change, so incompatible reports cannot be compared.

Use `measureOperation` around other Promise-returning backend modules. SQL
observation is exclusive per client: overlapping captures are rejected rather
than attributed using connection callbacks' unreliable async context. Its `drain`
argument is an explicit completion contract, not a sleep. Verification and fixture
queries stay outside this boundary. A zero-command database scenario fails its
budget check, catching an accidentally disconnected observer.

For Effect-backed operations, pass `() => Effect.runPromise(Effect.scoped(program))`
with the real required layers. Keep the scope alive for the operation and include
its finalizers; `measure.test.ts` exercises this boundary. Use the existing
`@effect/vitest` lane, `TestClock`, `Deferred`, scoped fibers and test layers for
logical time, cancellation and retry correctness. Use real monotonic time for
performance. Do not benchmark a virtual clock, launch unjoined daemon fibers or
substitute an in-memory repository when claiming a database optimization.

## Reference decisions

- [Bun isolation](https://bun.com/docs/test/parallel): preserve the existing
  isolated test lane and serialize cases sharing a database. Timing experiments
  use one worker so test parallelism does not become benchmark load.
- [Bun's benchmark runner](https://github.com/oven-sh/bun/blob/ba426210c28a43a3d36db504523617fd0202070e/bench/runner.mjs)
  uses [Mitata](https://github.com/evanwashere/mitata); its fixtures prepare inputs
  outside the measured callback. Use that style for CPU microbenchmarks. Here,
  explicit iterations allow equivalent mutable DB fixtures and correctness checks
  on every sample instead of adaptive repetition over growing state.
- [Effect's schema benchmark](https://github.com/Effect-TS/effect/blob/99d5575a1401b375b5a73f87fb5bf7e46c372f2f/packages/effect/benchmark/SchemaStruct.ts)
  separates preparation from Tinybench callbacks. That checkout is an older
  Effect version; API compatibility here is checked against this repository's
  installed Effect 4 beta.98. [TestClock](https://effect.website/docs/v4/testing/testclock)
  informs deterministic timing tests, not wall-clock measurement.
- [PostgreSQL protocol flow](https://www.postgresql.org/docs/current/protocol-flow.html)
  distinguishes SQL operations from extended-protocol exchanges. This is why the
  harness records both driver callbacks and actual frontend frame boundaries.

Report comparisons require the same fixture versions/cardinalities, scenario/RTT
matrix, runtime/driver/database/platform/CPU/pool settings, warmups and sample
counts. They report saved commands, exchanges and milliseconds separately, along
with before/after RTT calibration. A comparison is evidence to inspect, not an
automatic correctness proof or a promise of production latency savings.
