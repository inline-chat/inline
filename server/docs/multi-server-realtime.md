# Realtime across API processes

The ordinary delivery boundary produces recipient-specific `Update[]` values.
Local sockets receive those values immediately. When distributed realtime is
enabled, the same values are published as an encrypted, server-only Protobuf
message through the existing Redis connection pair. Remote gateways recheck
current access and send the existing client protocol locally, without republishing.
No Apple, SDK or CLI update is required.

## Configuration

| Deployment | Configuration | New coordination cost |
| --- | --- | --- |
| Single API, local development, Coolify | Omit Redis URLs and `INLINE_REALTIME_DISTRIBUTED` | No publication, discovery writes or discovery timer |
| Explicit single API with other Redis settings present | `INLINE_REALTIME_DISTRIBUTED=0` | Also disables the existing internal Redis transport |
| Multiple APIs | Same `REDIS_URL` (or `VALKEY_URL`) and encryption key on every API | Full live delivery plus temporary discovery metadata |
| Multiple APIs during broker removal/outage | `INLINE_REALTIME_DISTRIBUTED=1`, URL optional | Local delivery plus PostgreSQL discovery and existing client catch-up |

`INLINE_REALTIME_DISTRIBUTED` accepts only `0` or `1`. By default a configured Redis URL
enables it. Configure every writer consistently, including background API jobs.
The earlier `REALTIME_DISTRIBUTED` name remains accepted for compatibility. Both
names must contain `0` or `1` and agree when set together; prefer the `INLINE_`
name in portable deployment profiles.
There is no server registry, elected leader, required machine count, broker
persistence, new daemon or provider-specific dependency. Change configuration
when scaling back to one process; the system never guesses that a network
partition means it is safe to stop coordination.

## Complexity and data contract

The addition is one four-column temporary table, one private Protobuf message,
one bounded publication owner and one optional repair timer. Existing durable
update journals, authorization, socket delivery and broad repair remain the
sources of truth. There are no public RPCs or client schema changes.

```sql
recent_realtime_buckets (
  bucket integer,
  entity_id integer,
  seq integer,
  expires_at timestamptz,
  primary key (bucket, entity_id)
)
```

The row is updated in the **same transaction** as a durable journal insertion,
only when distributed mode is enabled. A higher sequence renews its five-minute
lifetime. Duplicate or older sequences do not prolong it. It contains no message
content and retains one frontier per recently active bucket, not event history.
An expiry index supports bounded deletion; table-specific autovacuum settings
support the update/delete churn. There are no foreign keys or recipient rows.

The private `RealtimeDelivery` Protobuf wraps existing `Update[]` with a version,
authenticated origin/event ID, expiry, exact recipient IDs or space target,
optional excluded session and ordered lane. The entire Protobuf is encrypted
with the existing AES-GCM facility; the small existing JSON transport envelope
carries its ciphertext. Its public client payload is unchanged. Sender message-ID
acknowledgements stay in order before the sender's message projection.

## Bounds and ordering

- The publisher retains at most 512 queued envelopes and 4 MiB, with at most
  256 KiB of update bytes per envelope and 256 recipient IDs. Normal payloads
  expire after five seconds; unsequenced reactions after two seconds.
- Sixteen lanes preserve each sender process's order within a bucket while
  allowing independent recipients to authorize concurrently. Chat/user updates
  partition by recipient; Space updates partition by Space, including broadcasts.
  Identical adjacent projections within a lane share one publication. Mutations
  are never collapsed into a newest-value payload. Existing client sequences
  reconcile independent writers; no global ordering or exactly-once promise is made.
- Existing receiver worker/count limits still apply, with an additional 8 MiB
  queued-byte bound. Private and revocation traffic retain reserved capacity.
  Local delivery never waits for Redis and unavailable Redis does not accumulate
  an offline publication backlog.
- Oversize frames, expiration, failed publication, and saturation use durable
  recovery. Reactions retain their existing best-effort, unsequenced contract.
  This work does not add reaction history or a client compatibility requirement.

## Recovery and database cost

Redis Pub/Sub can lose a publication. Every enabled API independently scans the
small recent-bucket index with bounded composite-key pages. The cursor is a
fair traversal cursor, **not a commit-order watermark**: it wraps, so a late
commit at a smaller key is discovered on a subsequent cycle. A one-second grace
lets normal full-payload delivery win. Exact frontier receipts are scoped to the
current local connection admission; they are not client acknowledgements.

Idle discovery runs about once a second while sockets exist. Full pages and an
overdue queue use 100 ms ticks, one page of at most 256 rows per tick. Repair
admits at most 16 buckets per tick, with at most four concurrent repairs. Healthy
unchanged frontiers do not repeatedly run recipient authorization. Existing
current-access helpers filter every repaired recipient. User-bucket recovery
includes the current record for released clients that ignore the newer hint.
Existing authenticated catch-up supplies pages and sidecars.

Expiry cleanup deletes at most 256 rows per query using `FOR UPDATE SKIP LOCKED`.
It normally runs every five seconds, accelerating through a backlog with bounded
100 ms ticks. Expiry is logical immediately; physical deletion and vacuum are
asynchronous. With all APIs in local-only mode, expired rows can remain until
coordination next runs, but no new rows are written. PostgreSQL does not provide
an automatic TTL deletion guarantee. Capacity and database health still matter;
this is a rate-bounded temporary index, not an unconditional hard byte quota.

The existing slower broad repair remains the safety net for old writers,
connections, mixed-version rollout and discovery continuity lost beyond the TTL.
A Redis outage aims for 2–5 seconds under a qualified workload; query latency,
active bucket count and overload can exceed that. Diagnostics expose pending
age, ongoing/completed scan-cycle time, failures, overflow and cleanup counts;
rate-limited warnings report missed five-second recovery bounds and live drops.

## Deployment and verification

Apply migration `0152_recent-realtime-buckets.sql` before enabling the new code.
Deploy one API first, then use identical mode, broker and encryption settings on
all APIs. Legacy durable references remain published for rolling compatibility;
new receivers give live payloads a grace before processing those references.
Old servers continue using their existing catch-up behavior until upgraded.

Qualification must distinguish server frame delivery from actual client rendering.
Local tests exercise independent processes using the production host lifecycle,
healthy full messages/edits/reactions and reverse delivery, session exclusion,
no redundant recipient chat hint in the healthy case, and automatic recovery
within five seconds with an absent or unavailable broker. Database tests cover
transaction rollback, concurrent frontier updates, TTL, late commits, bounded
cleanup, and access removal. Saturation/ordering/lifecycle tests cover bounded
queues and graceful ownership. These checks do not establish a production fleet
capacity or cross-region latency budget: qualify representative load and deployed
clients before directing traffic to the second machine.

Redis delivery semantics: https://redis.io/docs/latest/develop/pubsub/
PostgreSQL vacuum guidance: https://www.postgresql.org/docs/current/routine-vacuuming.html
