# Connected-user recovery discovery

A successful PostgreSQL commit can outlive its live notification. Redis Pub/Sub,
local queues and WebSocket acceptance do not acknowledge client application.
Periodic discovery repairs a lost final hint even if the socket and broker stay
connected. Changing its cadence changes the recovery delay; disabling it requires
another authoritative recovery mechanism.

## Strategy boundary

`modules/internalMessaging/repairDiscovery.ts` defines `RepairDiscovery`.
`ConnectedUserRepair` owns bounded scheduling, connection-epoch fences, checkpoint
advancement, user hints, legacy replay, retries and shutdown. Its injected
`discovery` strategy owns watermark capture, batch preparation and per-account
resource discovery. The default lives in `repairDiscovery.postgres.ts`; it writes
no durable state and leaves the public getUpdatesState RPC unchanged.

A replacement must preserve these rules:

- Capture a committed-write fence before preparing snapshots. Pair evidence with
  its fence; never advance a checkpoint from incomplete or failed discovery.
- A missing snapshot/frontier requires authoritative discovery. It does not
  imply the account is unchanged.
- Negative resource evidence is valid only for requests at or after its inclusive
  `resourcesUnchangedSince` and no later than its watermark. Delayed evidence
  cannot regress a newer checkpoint or skip an older request.
- Candidates are not authorization. Recheck current access before hint delivery;
  honor `shouldEmitHints` when the connection lifetime ends.
- Return the authoritative user sequence even without resource changes. User-only
  recovery and legacy replay remain the scheduler's work.
- Join admitted preparation/discovery on shutdown and retry failures without
  advancing the previous checkpoint.

A durable journal can later replace this strategy while preserving client-facing
recovery guarantees. Retrying Pub/Sub publication alone does not make consumption
resumable. A journal also needs receiver checkpoints, complete writer coverage,
safe commit ordering, retention and an authoritative fallback.

## Older-client recovery

Hint-aware clients fetch their authenticated user bucket after `userHasNewUpdates`.
Older clients also receive the latest actual access-filtered record. If that
record is missing or filtered, the server closes the current connection epoch
with the existing `durable_repair` reason so the client's on-open catch-up runs.
No synthetic durable record is invented. Current connection metadata cannot
reliably identify hint support, so this rare fallback can also reconnect a newer
client.

The existing connection owner remembers the highest unreplayable frontier it
closed and suppresses it across admission and observation pruning. It retains
at most 4,096 guards and never evicts a guard inside its 30-second cooldown. If
all entries are protected, a new fallback remains pending for another sweep.
Capacity eviction after the cooldown, or a process restart, can permit another
reconnect for the same frontier. Under sustained capacity pressure repeated
reconnects remain possible after the cooldown; this is not durable client
acknowledgment or a once-forever guarantee. Monitor fallback-close rates.

## Current optimization

The PostgreSQL implementation checks at most 512 accounts per SQL batch. It
reconciles user sequences against retained update history and separately finds
accounts with potentially changed resources. The query deliberately includes a
superset of the normal catalog: both DM endpoints, all chats in member spaces,
dialog-backed threads, private Home roots with direct participants (including
participants without dialogs), and member spaces. Private/deleted or inaccessible
candidates can cause extra work, but never grant access. Changes in unrelated
spaces do not make every account dirty.

Accounts without candidates skip full chat/space discovery. Changed accounts use
the existing getUpdatesState path, including current access checks, sequence
reconciliation and bounded hint delivery. Comparisons are inclusive and use
explicit UTC conversion for timestamp-without-time-zone columns. A mutation
after preparation remains discoverable at the next watermark.

For the synthetic 1,000-user/five-shared-chat fixture:

| Workload | Previous batched-frontier strategy | Current strategy |
| --- | ---: | ---: |
| Idle | 3,006 commands | 8 commands |
| Ten accounts with changed DMs | 3,016 commands | 48 commands |
| Every account has a changed shared chat | 5,006 commands | 5,008 commands |

Counts include fence/transaction commands. An uncontended idle sweep costs
`4 + 2 * ceil(users / 512)` commands. Changed accounts still add authoritative
queries. Fewer commands do not imply constant database work: joins depend on
membership/chat cardinality. This targets idle and sparse activity; it does not
solve busy shared-room fanout or establish production capacity.

## Regression checks and observability

From `server/`, with a local PostgreSQL role that can create test databases:

```sh
TEST_DATABASE_URL=postgres://localhost:5432/postgres bun run test:repair --jobs 1
```

Normal CI Bun/PostgreSQL lanes also discover these tests. Correctness cases cover
DM endpoints, public/private/group/linked/Home chats, participants without
dialogs, lost Home pin/unpin hints, spaces, current access, retained
sequences, user-only missed hints, inclusive boundaries, stale/missing snapshots,
prepare failures and shutdown. Performance cases cover 1, 10, 100 and 1,000 users,
idle/shared/sparse activity, 1,005 shared chats, and the actual scheduler-to-strategy path. Command
budgets fail on regression; a generous elapsed ceiling catches catastrophic
stalls. JSON timings support local comparison, not production p95 claims. Review
budget changes rather than automatically regenerating them.

Preparation logs aggregate user/candidate/batch counts and duration, warning at
500 ms; they contain no user IDs or payloads. Existing maximum repair age and
per-account slow discovery logs remain relevant. Before rollout, measure actual
membership cardinality, broker loss, repair delay and concurrent RPC latency
against the intended database/network configuration.
