# Recover database-dependent service

Use this procedure when API latency, realtime recovery, database errors or
readiness indicate database pressure or loss of connectivity. Start with
read-only evidence. Assign an incident owner and record the UTC window, affected
user paths, serving image/revision, database branch and any recent release,
resize or maintenance. Keep credentials, query parameters and message content
out of receipts.

## Capture before changing the system

Inspect the public path and provider metadata using existing managed access:

```sh
curl --fail --silent --show-error --max-time 3 https://api.inline.chat/readyz
fly status --app inline-api
pscale branch show inline-prod main --org inline-chat --format json
pscale backup list inline-prod main --org inline-chat --format json
pscale backup policy list inline-prod --org inline-chat --format json
```

Readiness checks database access, required migrations, clock safety and lifecycle.
In PgBouncer mode it checks both the pooled query path and the direct health
path. Its database deadline is bounded. A passing probe does not establish
normal RPC latency or successful reconnect and replay.

For the incident window, inspect PlanetScale CPU, memory/OOM events, connection
states, PgBouncer waiting clients and wait duration, locks, WAL archive health,
and Query Insights. Compare query execution counts, CPU/total time, rows read,
errors and latency with the preceding healthy window. A correlated query can be
a victim of pressure; correlation alone is insufficient reason to change it.
Capture application request/replay latency and backlog alongside database
metrics so pool waiting can be distinguished from SQL execution time.

Do not start with a database restart, terminate sessions, remove upload/replay
fences, run a backup restore or launch another writer. Preserve the evidence that
distinguishes resource pressure, a blocked query, connection exhaustion and a
provider event. Avoid broad raw-log or raw-query collection.

## Choose the recovery path

| Evidence | Response |
| --- | --- |
| CPU, memory, locks or pool waiting rises while the database remains reachable | Identify the expensive caller or constrained resource. Reduce implicated work or choose a measured capacity change; retain interactive and health headroom. |
| Database connectivity fails | Check provider maintenance/availability and both connection paths. Moving API hosts preserves the same database dependency. |
| A release introduces a regression | Select a tested compatible image and its matching configuration. Use the [deployment rollback procedure](fly-deployment.md#migration-safety-and-rollback). |
| The live database is lost or logically damaged | Select an exact recoverable point and restore in isolation. Complete the application recovery gates below before changing authority. |
| An independent backup is stale or incomplete | Inspect the original snapshot/scan age, durable closure and exact remote versions. Reconcile uncertain writes before retrying. |

Budget the entire fleet before resizing a query pool or adding API instances:
normal APIs, blue-green overlap, standby, direct health slots and operational
connections all consume capacity. PgBouncer client limits differ from backend
connection limits. More admitted queries can increase pressure without improving
latency. Verify effective configuration and timeout defaults after a change;
checked-in defaults alone do not prove the running settings.

## Restore an isolated point

Application rollback and database restore are different operations. Provider
snapshots and PITR depend on their available restore window. Independent exports
support a provider escape with their own source age and restore time. A schedule
or successful upload does not establish a recovery-point objective.

Before selecting a point, record the original snapshot timestamp, exact backup
or object-version identity, schema, compatible image/configuration, encryption
key generations and required object storage. Confirm current backup freshness
and usable restore endpoints; use the operator recovery catalog for private
locations and access instructions.

Restore into an isolated target, then verify SQL integrity, migration state,
sample authenticated decryption and required attachments. Retain the original
database and failed attempts. Record download, decrypt, SQL restore and
application qualification time separately.

Before promoting restored state:

1. Stop and independently fence every old API, socket admission, worker and
   operational writer. A DNS switch does not fence workers or existing sockets.
2. Accept the selected lost tail and account for restored access revocations,
   ownership and credentials. Verify that private data cannot be exposed through
   revived grants.
3. Prevent reuse of issued identifiers and validate client state rebuild when
   local messages or cursors are newer than the restored point. Preserve pending
   local material while reconciling it.
4. Keep workers stopped while reconciling external effects whose completion was
   lost. Restored claims do not prevent repeating an already delivered effect.
5. Update pooled and direct database endpoints consistently, admit a restricted
   qualified API, then deliberately admit reconciled workers and customer paths.

If a required fence or recovery mechanism is unproven, report that limitation and
keep promotion restricted. After new writes on the recovered authority, failback
requires resynchronization; changing back to the old database URL is insufficient.

## Verify recovery and maintain alerts

Require a successful authenticated request, fresh realtime connection and
bounded replay for the affected clients, plus relevant worker/backlog recovery.
Record restored readiness and the actual user-path outcome separately. Continue
observing latency, pool waiting, errors and memory after the immediate symptom
clears. Close the incident with the owner, mechanism, recovery evidence and any
remaining acceptance limits.

Use an independent alert route for database-down/database-up transitions and
external endpoint failure; delivery must continue when Inline cannot store or
send a message. A monitor inside the API cannot detect its own stopped process.
Keep alert delivery best effort and outside startup/readiness requirements.

Maintain explicit owners and recovery links for sustained CPU pressure,
available-memory pressure and OOM events, backend/pool waiting, request/replay
latency, readiness failure, stale successful backups and WAL archive failures.
Choose thresholds from a healthy baseline and recovery objectives. Test real
notification delivery and recovery without sending synthetic backup success.
Inspect current alert state and acknowledgement; a historical alert test does not
prove that today's incident reached an operator.

References: [PlanetScale PITR](https://planetscale.com/docs/postgres/backups/point-in-time-recovery),
[PlanetScale monitoring](https://planetscale.com/docs/postgres/monitoring/metrics),
[PlanetScale OOM prevention](https://planetscale.com/docs/postgres/troubleshooting/out-of-memory#monitoring-and-prevention),
and [Fly health checks](https://fly.io/docs/reference/health-checks/).
