# Sync Engine Deep Dive (2026-02-07)

## What Exists Today (End-to-End)

### Server
- Per-entity update buckets stored in Postgres `updates` with `(bucket, entity_id, seq, date, payload)` and an index on `(bucket, entity_id, seq)`.
  - `bucket` enum: Chat=1, User=2, Space=3. (`server/src/db/schema/updates.ts`)
  - Chat/Space seq is maintained by locking the row and incrementing `update_seq`, updating `last_update_date`. (`server/src/db/models/messages.ts`, plus various `server/src/functions/*`)
  - User bucket seq is maintained by selecting latest seq `FOR UPDATE` from `updates` and inserting next. (`server/src/modules/updates/userBucketUpdates.ts`)
- `getUpdates` RPC:
  - Reads DB updates in slices (server-enforced `MAX_UPDATES_PER_REQUEST=50`), inflates chat updates by fetching messages/chats, and returns `seq`, `date`, `final`, `resultType`. (`server/src/functions/updates.getUpdates.ts`, `server/src/modules/updates/sync.ts`)
  - Returns `TOO_LONG` when `(latestSeq - startSeq) > totalLimit` (capped to 1000). (`server/src/functions/updates.getUpdates.ts`)
- `getUpdatesState` RPC:
  - Takes a **date** cursor and finds chats/spaces with `lastUpdateDate >= cursor`.
  - Side-effect pushes `chatHasNewUpdates` / `spaceHasNewUpdates` over realtime updates, and returns only `{ date }`. (`server/src/functions/updates.getUpdatesState.ts`)

### Apple Client (RealtimeV2)
- `RealtimeV2.Sync` actor:
  - Applies most updates directly.
  - Treats `chatHasNewUpdates`/`spaceHasNewUpdates` as “signals” and triggers per-bucket fetch (`BucketActor.fetchNewUpdates()`).
  - On connect: always fetches user bucket + calls `getUpdatesState`. (`apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift`)
- `BucketActor`:
  - Calls `getUpdates` in a loop until `final=true`.
  - Filters update types during catch-up using `enableMessageUpdates` toggle (experimental). (`apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift`)
- Experimental flag:
  - “Enable sync message updates” toggles whether `.newMessage/.editMessage/.messageAttachment` are applied during catch-up. (`apple/InlineIOS/Features/Settings/ExperimentalView.swift`, `RealtimeConfigStore`)
- Update application:
  - `UpdatesEngine.applyBatch` runs update-specific `apply` methods inside a GRDB write transaction. Many message-related applies have realtime side effects (unread count increment, notifications, per-message publisher events). (`apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift`)

## High-Confidence Problems

### Correctness / Reliability
1. **Out-of-order seq can cause skipped updates** when catch-up is enabled.
   - Bucket fetch currently treats `seq <= self.seq` as a duplicate. If a newer direct update advances `self.seq` before catch-up applies older missing seqs, those older updates get dropped.
   - This is especially dangerous for `.newMessage` because the apply path is not idempotent (it increments unread counts, may trigger notifications).
2. **No per-bucket sequencing for direct updates.**
   - `Sync.process()` applies direct updates immediately; there is no “expected next seq” enforcement, buffering, or gap detection.
   - Missing a seq should trigger `getUpdates` for that bucket and block applying later seqs until the gap is filled.
3. **`getUpdatesState` can return `date=0` when there are no updated chats/spaces**, so the client cursor never advances.
   - This causes repeated rescans/signals on each connect and can cascade into fetch storms.
4. **`getUpdatesState` relies on side-effect pushing signals**, but the RPC result doesn’t carry them.
   - This is fragile: if those pushed updates are missed/delayed, the client has no authoritative list of buckets that need fetching.
5. **`TOO_LONG` is currently handled by fast-forwarding without resync.**
   - Client can silently skip huge ranges of updates and never repair local state (commented TODO in client confirms missing recovery).
6. **Bucket fetch failures are “fire and forget”.**
   - On RPC error, a bucket can stay behind forever if there is no future signal for that bucket.

### Performance
1. **Catch-up applying message updates replays realtime side effects.**
   - On macOS: notifications may fire for historical messages.
   - UI: `MessagesPublisher` emits per-message updates; large catch-up batches can cause main-thread storms.
2. **No global throttling for bucket fetches.**
   - `chatHasNewUpdates` can spawn many concurrent fetch tasks across buckets.
3. **Some update types are not persisted in sync DB at all (eg. reactions, messageAttachment).**
   - “Full sync” can never truly be complete unless these are stored or reconstructed elsewhere.

## Proposed Fix Direction (Concrete)

### Phase 1 (Make It Correct + Stop Obvious Storms)
1. Server: fix `getUpdatesState` to return a sensible date when there are no results (eg. `now`), so the cursor can advance.
2. Client: implement **per-bucket sequencing** for seq-bearing updates:
   - Route bucket-keyed updates with `seq` into `BucketActor` (or a new per-bucket queue).
   - Enforce `expectedSeq = lastSeq + 1`.
   - Buffer out-of-order updates, trigger `getUpdates` to fill gaps, then drain buffer.
3. Client: add retries/backoff for bucket fetch failures (and a global concurrency cap).

### Phase 2 (Make Full Sync Safe for Messages)
1. Introduce an apply “source”/context:
   - `realtimePush` vs `syncCatchup`.
   - Suppress notifications and per-message publisher events in catch-up; prefer a coalesced reload per peer.
2. Make message apply idempotent:
   - Avoid incrementing unread or emitting publisher events if the message already exists.

### Phase 3 (TOO_LONG Recovery + Scalability)
1. Implement a real TOO_LONG strategy:
   - Option A: server returns a slice boundary `seq` for incremental catch-up (so `seq_end` becomes meaningful).
   - Option B: treat TOO_LONG as “differenceTooLong” and trigger a higher-level resync (refresh chats list / chat history) and clear stale local caches.
2. Decide whether “full sync” includes reactions/attachments:
   - Persist those as bucket updates, or accept that they are eventually-consistent via history fetch.

## Notes
- The current code already hints at the desired direction: `Sync.process()` has a TODO to route updates through `BucketActor` “to ensure strict ordering with fetched history”.
- The experimental toggle is the right feature gate, but enabling it requires fixing sequencing + side effects first.

## Implemented (Second Pass)

- Apple: global `getUpdates` concurrency limiter (configurable via `SyncConfig.maxConcurrentBucketFetches`) to prevent reconnect fanout from overwhelming the server.
- Apple: fix for a correctness bug where an in-flight fetch could regress persisted bucket `seq` behind newer realtime-applied updates (actor reentrancy).
- Apple: additional Sync unit tests:
  - out-of-order realtime buffering + gap repair
  - global limiter concurrency cap
  - no-seq-regression on fetch completion
- Apple: `getUpdates` `TOO_LONG` now supports **incremental slicing** even against legacy servers that return `latestSeq` (derives `seqEnd = currentSeq + 1000` instead of fast-forward skipping).
