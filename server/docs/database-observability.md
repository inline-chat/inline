# Investigating database CPU

Compare the same UTC window in node metrics, PlanetScale Insights, and server
logs. A query's share of measured query CPU is not its share of total node CPU.
Check CPU, query count, transaction rate, PgBouncer waiting clients, active/idle
backends, and backups before changing pool limits or instance size.

## Application diagnostics

After successful database startup, `db.diagnostics` emits an INFO-level
`Database connection configuration` record with the effective connection mode,
local query/health pool limits and enforced timeouts. It emits a
`Database operation window` per active operation every 60 seconds, including
fast operations that otherwise disappear at the production WARN log level.
The existing logger sends these records to stdout and Sentry Logs.

Fields include `windowMs`, `completed`, `failed`, `totalMs`, `maxMs`,
`atLeast100Ms`, `atLeast500Ms`, `workItems`, `inFlight`, and `peakInFlight`.
Reporting is best-effort and stops/flushed during database shutdown. No SQL,
bindings, user/chat IDs, cursors, connection URLs or error messages are recorded.

- `access.*` measures the canonical chat-access query by caller, including
  client queueing/network time. `workItems` counts requested chats. The SQL also
  carries fixed SQLCommenter tags: `application=inline-server`,
  `operation=chat_access`, and `source` (`sync.replay`, `sync.sidecars`,
  `repair.chat`, `chats.list`, `messages.send`, `realtime.delivery`, or the
  fallback `authorization`). Tags must be trailing comments: a live prefix vs
  suffix probe confirmed PlanetScale records only the suffix. Embedded delivery
  queries use an outer `operation=live_delivery` tag and are not separately timed.
- `replay.{user,space,chat}.{total,resolve,fetch,inflate,sidecars}` aggregates
  completed getUpdates requests and their existing phase timings. For `total`,
  `workItems` counts fetched journal records, including records later removed
  by compatibility page sizing. Failures before page completion are not included;
  use existing request errors and the underlying access/transaction failures.
- `transaction.admission` measures time until Drizzle enters the transaction
  callback: pool admission **plus** BEGIN and transaction configuration round
  trips. It is not an exact pool-wait metric. Admission failures appear in
  `transaction.total.failed` and have no admission completion.
- `transaction.total` measures the outer transaction through commit/rollback;
  pending transactions remain visible in `inFlight` across reporting windows.
- `replay.{scope}.{clientType}.{first,advance,repeat,rewind}` counts completed
  replay requests by cursor movement relative to the previous request for that
  connection/bucket (session fallback for callers without a connection ID).
  `workItems` counts fetched records; repeated empty polls have
  zero work. Duration is zero for these counters. Coordinates stay in a bounded
  4,096-entry process-local LRU with a ten-minute idle expiry and are never logged.
  Missing connection metadata becomes `unknown`. A repeat or rewind is evidence
  to investigate, not proof of a defective client; retries can be legitimate.
  Separate sockets sharing a session are tracked independently. Failures before
  completion are excluded. Restart/eviction/expiry resets classification to `first`.
- `replay.user.throttled` counts requests stopped before journal fetching by
  the replay-loop guard. On one connection, the first rewind of 1,000 or more
  sequences is allowed; a second triggers 60 seconds of backoff, doubling up to
  five minutes for further rewinds. Clients receive the existing RATE_LIMIT
  error. Forward catch-up, small page retries and empty polling are unrestricted.
  Progress beyond the previous high-water start bypasses a pending pause.
  The guard is a bounded 4,096-entry process-local LRU with ten-minute idle
  expiry, and never changes persisted cursors, access decisions or history.
  Reconnects reset its protection; this is load containment, not client repair.

Durations overlap: never add replay, access and transaction totals as if they
were independent CPU measurements. Completion latency is charged to the window
where it completes; it may exceed that window for long-running operations.
`inFlight`/`peakInFlight` describe observed operations, not physical connections.

Filter Insights with `tag:operation:chat_access` and `tag:source:sync.replay`.
Compare rate (`completed / windowMs * 1000`), batch size
(`workItems / completed`), latency and failures with node CPU. A rise in replay
and sidecar volume without slower individual queries suggests repeated catch-up
or reconnect work. Investigate cursor progress at the client/request boundary
before changing authorization semantics or retaining cached access decisions.

## Planning and connection checks

The installed Drizzle postgres-js adapter uses `client.unsafe(query, params)`;
postgres.js defaults this path to `prepare: false`, even when the client has
`prepare: true`. Repeated complex queries can therefore incur planning cost.
Use bounded `EXPLAIN (FORMAT JSON, SUMMARY TRUE)` to inspect planning without
executing the query. Synthetic bindings establish a planning-cost lead, not
the execution cost of real requests. Do not enable prepared statements globally
without qualifying the actual PgBouncer configuration, changing batch shapes,
transactions and deployment overlap.

The shared query client now prepares only tagged `sync.replay` and
`sync.sidecars` access queries with at most 301 parameters (100 chat IDs used
three times, plus one user). Their two sources yield at most 200 statement
shapes per connection. Larger batches retain the existing driver behavior. The same bounded policy
also applies to transactions, savepoints and reserved clients. Explicit `prepare: false` is respected. This caches
plans, never permissions or results. Production PgBouncer was verified to use
transaction mode with `max_prepared_statements=200`; keep this capability when
changing providers or pool configuration. Local integration tests exercise
actual Drizzle prepared reads through PgBouncer, and authorization tests cover
revocation after warm repeated reads. Array-binding alternatives were rejected
after historical live probes showed PostgreSQL kept replanning them instead of
selecting the faster generic plan for that query shape. This is evidence for the
narrow family, not for enabling generic plans across all queries.

Broader preparation requires explicit `INLINE_DATABASE_PREPARED_QUERIES=all-custom`
and an operator-established `force_custom_plan` default on the query role. The
startup and readiness probes inspect `plan_cache_mode` through the query pool;
startup rejects unqualified opt-ins, and readiness disables broad admission if
the sampled backend loses qualification. Establish the role default and recycle
existing PgBouncer backend sessions before enabling it: sampling one backend
does not prove the setting on every backend. No role or session settings are
changed by this code. See [the prepared-query policy](../BENCHMARKING.md#prepared-query-policy)
for the bounded second-observation admission policy and benchmark limits.

Replay access checks execute the canonical SELECT directly on the shared
client. The former single-query explicit transaction added BEGIN/SET/COMMIT
round trips and used an unprepared transaction client. Removing that wrapper
retains PostgreSQL's single-statement snapshot across all CTEs; journal page
reads still use their existing multi-query repeatable-read transaction.

Inspect `pginsights.raw_queries` for the effective raw-query collection state;
the database API's separate boolean is not authoritative for Postgres. Raw
collection exposes literal values to the telemetry pipeline and is unnecessary
for these operation tags. Restricted `pg_stat_activity` fields are unknown, not
evidence of idle backends. No new permissions or database settings are needed
for the application diagnostics above.
