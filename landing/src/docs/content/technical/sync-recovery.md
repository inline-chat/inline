---
title: "Sync Recovery"
description: "Recover gaps, reconcile snapshots, and distinguish update continuity from message history."
---

Use this page when a live sequence skips ahead, discovery reports a changed bucket, or `GET_UPDATES` cannot replay the requested range. Recovery is per bucket: retain the last safe cursor and cached projection until missing coverage is applied or an authoritative replacement is complete. For the basic model, see [Sync](/docs/technical/sync).

## Recover a gap

Suppose a chat is durably applied through sequence 41 and a live event arrives at 44. Pause admission for that chat, preserve cursor 41, and request `GET_UPDATES` from 41. Validate that each response accounts for every sequence through its returned `seq`, apply its updates, and persist progress before requesting the next page. Resume live admission only after the required target is covered. An unrelated chat remains live throughout.

```text
on durable event(bucket, seq):
  if seq <= committed_cursor(bucket): ignore duplicate
  if seq > next_expected(bucket): fence bucket; request catch-up
  else: apply event; acknowledge host delivery; commit coverage

while bucket is fenced:
  page = GET_UPDATES(bucket, start_seq = committed_cursor(bucket))
  if page is TOO_LONG: use the bucket's authoritative-repair policy
  else: validate every sequence; apply page; commit projection and cursor
  repeat until target is covered
```

This pseudocode describes decisions, not a copyable SDK API. A host with asynchronous event handlers must wait for already admitted live work before replaying the same range. On failed apply, invalid page, inaccessible bucket, or non-progress response, retain the safe cursor and report or retry the specific failure. Do not advance across malformed or unsupported durable work without authenticated sequence coverage.

## `TOO_LONG` and snapshot ownership

The server caps `GET_UPDATES` at 100 logical records per page. It returns `TOO_LONG` with an authoritative sequence pointer when the requested replay range exceeds 10,000 sequence positions, or when the retained journal has a gap. Without an explicit `seq_end`, the range ends at the bucket's current sequence. The request's `total_limit` field is deprecated; the server owns this replay ceiling. An explicit `seq_end` can bound a request, and the TypeScript SDK uses such windows to replay a long retained backlog in successive ranges. A total backlog above 10,000 therefore does not by itself mean the TypeScript SDK immediately replaces a snapshot.

Recovery depends on who owns materialized state:

| Client owner | On `TOO_LONG` or a snapshot-repair marker |
| --- | --- |
| Materialized-state host | Fetch complete authoritative state for the affected bucket, durably replace the bucket-owned projection, and return a cursor covering the server target. If replacement fails, keep the old cursor and degraded status. |
| TypeScript SDK without `repairUpdatesBucket` | Continue bounded replay where possible. If a bounded range still cannot be replayed, the SDK advances to the server-authoritative pointer for liveness and logs lost replay coverage. This is not a complete projection repair; an event-only consumer must reconcile its own state if it needs completeness. |
| Rust client built-in store | Repair the bucket's owned snapshot, then commit replacement events and the cursor together. Its cold chat snapshot includes the newest bounded message window; older history remains a separate concern. |

The TypeScript `repairUpdatesBucket` callback receives `{ bucket, serverSeq, serverDate }`. It must durably apply a complete bucket replacement and return `appliedSeq >= serverSeq`; a partial overlay is insufficient. The SDK marks the bucket degraded and preserves its previous cursor when the callback fails or returns a cursor behind the target. The callback is optional for event-only hosts, but omitting it accepts the liveness leap described above.

For chat repair, preserve cached older messages unless an explicit deletion or history-clear operation covers them; a newest-message snapshot is not a full historical transcript. Preserve user-owned dialog preferences and other state outside the repaired bucket's authority. Validate snapshot bucket identity and covered sequence before committing it.

## Discovery failures

Discovery uses a date checkpoint to find changed buckets, then each bucket's sequence to apply them. Keep the old date checkpoint until preceding hint batches, bucket targets, and checkpoint persistence succeed. If the discovery RPC or state-store write fails, retry from that prior date. Do not invent a later date from the local clock: that can skip work committed while the client was offline.

The server's discovery scan is inclusive. A repeated hint is normal; compare it with the bucket cursor before fetching. A hint with sequence zero means “fetch authoritatively,” not “nothing changed.” An access rejection for a formerly visible chat or space can retire that fetch demand; it does not, on its own, prove cached content should be deleted.

## History continuity

An update cursor certifies delivery or accounted skipping of update records. It does not certify that every message in a chat history interval is stored locally. An initial or repaired chat snapshot may contain only recent messages; older pages are fetched through history APIs. Track local message-history coverage separately, request the missing interval, and mark it continuous only after a successful authoritative history response. Do not infer that two stored message IDs are adjacent merely because the chat update cursor is current.

## Implementation sources

- [Server replay and `TOO_LONG` behavior](https://github.com/inline-chat/inline/blob/main/server/src/functions/updates.getUpdates.ts)
- [Server discovery behavior](https://github.com/inline-chat/inline/blob/main/server/src/functions/updates.getUpdatesState.ts)
- [TypeScript SDK repair contract](https://github.com/inline-chat/inline/blob/main/packages/sdk/src/sdk/types.ts)
- [TypeScript SDK catch-up implementation](https://github.com/inline-chat/inline/blob/main/packages/sdk/src/sdk/inline-sdk-client.ts)
- [Rust client repair implementation](https://github.com/inline-chat/inline/blob/main/crates/client/src/sync.rs)
