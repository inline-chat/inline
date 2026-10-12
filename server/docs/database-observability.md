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
  fallback `authorization`). Embedded live-delivery queries carry the tag but
  are not separately timed by this helper.
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

Inspect `pginsights.raw_queries` for the effective raw-query collection state;
the database API's separate boolean is not authoritative for Postgres. Raw
collection exposes literal values to the telemetry pipeline and is unnecessary
for these operation tags. Restricted `pg_stat_activity` fields are unknown, not
evidence of idle backends. No new permissions or database settings are needed
for the application diagnostics above.
