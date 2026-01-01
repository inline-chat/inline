# RealtimeV2 Sync Overview (InlineKit)

## High-level flow
- Transport receives server messages (WebSocket) and emits transport events.
- ProtocolClient parses messages into client events (open/connecting/ack/rpcResult/updates).
- RealtimeV2 listens to client events and forwards update batches to Sync.
- Sync applies most updates directly and triggers per-bucket fetching when the server notifies that a bucket has new updates.
- BucketActor fetches bucket history via getUpdates, filters supported update types, applies them in a batch, and persists bucket state.
- Sync exposes a lightweight stats snapshot for debug/production observation.

## Modules involved in sync (current wiring)
- Transport layer
  - `apple/InlineKit/Sources/RealtimeV2/Transport/WebSocketTransport.swift`
    - Manages websocket lifecycle and emits `TransportEvent` messages.
- Protocol client
  - `apple/InlineKit/Sources/RealtimeV2/Client/Client.swift`
    - Turns transport events into `ClientEvent` values.
    - Emits `.updates` events when server sends update payloads.
    - Provides `callRpc` for sync RPCs (default timeout 15s).
- Realtime orchestrator
  - `apple/InlineKit/Sources/RealtimeV2/Realtime/Realtime.swift`
    - Listens to ProtocolClient events and calls `sync.process(updates:)`.
    - On connection state changes, forwards to `sync.connectionStateChanged`.
- Sync core
  - `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift`
    - Splits pushed updates: `chatHasNewUpdates` and `spaceHasNewUpdates` trigger bucket fetches.
    - All other updates are applied directly (no bucket ordering yet).
    - Uses `getUpdatesState` on connect to prompt server to emit hasNewUpdates events.
    - Tracks per-bucket seq/date in storage.
- Bucket state storage
  - `apple/InlineKit/Sources/RealtimeV2/Sync/SyncStorage.swift`
  - `apple/InlineKit/Sources/InlineKit/RealtimeAPI/GRDBSyncStorage.swift`
    - Persists global lastSyncDate and per-bucket seq/date in GRDB.
- Applying updates to local DB
  - `apple/InlineKit/Sources/RealtimeV2/Sync/SyncApplyUpdate.swift`
    - Protocol abstraction for applying updates.
  - `apple/InlineKit/Sources/InlineKit/ApplyUpdates.swift`
    - `InlineApplyUpdates` calls `UpdatesEngine.shared.applyBatch`.
  - `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift`
    - Applies updates to the database via GRDB with per-update handlers.

## Sync lifecycle details
- Connection established
  - RealtimeV2 receives `.open` and calls `sync.connectionStateChanged(.connected)`.
  - Sync triggers `fetchUserBucket()` and `getUpdatesState(date: lastSyncDate)`.
- getUpdatesState
  - Sync loads lastSyncDate from SyncStorage.
  - If uninitialized or too old, it seeds/reset the date and saves it.
  - Sync sends `getUpdatesState` RPC to server.
  - Server is expected to respond by pushing `chatHasNewUpdates` / `spaceHasNewUpdates` for affected buckets.
- Pushed updates
  - Sync.process() applies most update types directly via UpdatesEngine.
  - `chatHasNewUpdates` and `spaceHasNewUpdates` do not apply updates directly; they trigger per-bucket fetch.
- Bucket fetch
  - BucketActor calls `getUpdates` with bucket + `startSeq`.
  - If result type is TOO_LONG and gap > max total, it fast-forwards to server seq/date and discards pending updates.
  - If result type is TOO_LONG and gap <= max total, it requests a sliced range using `seq_end`.
  - Otherwise it filters updates using `shouldProcessUpdate` and applies them in a batch.
  - It saves bucket seq/date in SyncStorage.

## Current bucket filtering behavior
- In catch-up, BucketActor only processes structure/cleanup updates:
  - spaceMemberAdd, spaceMemberUpdate, spaceMemberDelete
  - participantDelete
  - deleteChat
  - deleteMessages
- It skips message updates in sync catch-up today (new/edit/attachment/etc).

## Notes and constraints (current implementation)
- Ordering between bucket fetch and direct realtime updates is not enforced yet.
- Sync uses additive-only application and does not halt on failures; errors are logged.
- Persisted bucket state (seq/date) is the source of truth for future fetches.

---

# Plan to address requested issues (no hard stops, additive-only)

## 1) Fix missed fetchNewUpdates during in-flight fetch
Goal: Never miss new updates if a `hasNewUpdates` arrives while a bucket fetch is running, without enforcing strict ordering or blocking the app.
- Add a per-bucket `needsFetch` flag (or a counter) that is set when `fetchNewUpdates` is called while `isFetching == true`.
- At the end of `fetchNewUpdates`, if `needsFetch` is true, clear it and immediately loop another fetch.
- Keep it bounded (e.g., max N consecutive re-fetches or short delay) to avoid infinite loops in noisy scenarios.
- Log when a fetch is coalesced and when a follow-up fetch is triggered.

## 2) Add a flag to enable new message-related updates in sync catch-up
Goal: Allow a controlled rollout for syncing message updates via bucket fetch.
- Introduce a config toggle in Sync/BucketActor (e.g., `SyncConfig.enableMessageUpdates`), default off.
- When enabled, extend `shouldProcessUpdate` to include:
  - newMessage
  - editMessage
  - messageAttachment
- Add a targeted log that reports when these types are skipped vs processed.
- Keep direct realtime updates unchanged, so sync remains additive-only.

## 3) Improve logging for debugging and verification
Goal: Make it easy to trace missing updates and understand bucket progress in dev.
- Add log lines for each getUpdates request/response with:
  - bucket key
  - startSeq, payload.seq, payload.date, payload.final, payload.resultType
  - counts: total updates, filtered-in updates, filtered-out updates
- Log when bucket state is persisted with seq/date.
- Log when a duplicate update is dropped (include seq and bucket).
- Ensure errors include bucket key + seq context.

## 4) Advance global lastSyncDate with a safety gap
Goal: Ensure `lastSyncDate` advances after successful application while maintaining a buffer.
- Track the max applied update date across both direct updates and bucket fetches.
- After a successful apply batch, persist `lastSyncDate = maxAppliedDate - safetyGapSeconds` (clamped to >= 0).
- Keep this non-blocking: update failure should not halt sync flow.
- Add logs that include previous date, new date, max applied date, and gap seconds.

## Verification strategy (dev-focused)
- Add a debug-only mode (or log level) that prints detailed fetch/responses.
- Use a synthetic test path:
  - connect, send `getUpdatesState`, trigger `chatHasNewUpdates` repeatedly while fetch is in progress.
  - confirm follow-up fetch occurs and seq advances without loss.
- Validate message updates toggle:
  - toggle off: no message updates applied via bucket; toggle on: new/edit/attachment applied.
- Confirm failures do not block future fetches and seq/date persist.
- Validate `lastSyncDate` advances to `maxAppliedDate - safetyGapSeconds` and does not regress.

---

# Implementation status (current)
- DONE: Follow-up fetch queueing via `needsFetch` with stats for follow-ups.
- DONE: `SyncConfig.enableMessageUpdates` gating for new/edit/attachment updates.
- DONE: `lastSyncDate` updates use max applied date minus safety gap.
- DONE: Structured logging around bucket fetches, skips, and state updates.
- DONE: Debug stats snapshot via `RealtimeV2.getSyncStats` with UI surfaces on iOS/macOS.
- DONE: Backend `seq_end` support and client slicing for TOO_LONG within max total.
