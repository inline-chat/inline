# Fresh iOS Startup Log Triage

Date: 2026-06-07

## Summary

Fresh iOS startup is mostly progressing through normal realtime startup, but the logs expose two production-significant issues:

- Local database writes are failing foreign-key constraints during fresh sync/load and can leave partial client state.
- `WebSocketTransport.sendPing(fastTimeout:)` leaks a checked continuation on timeout/cancellation paths, which can suspend realtime health tasks forever.

The app is not production-ready with these logs until those two issues are fixed.

## Normal / Expected

- `RealtimeWrapper | Starting realtime connection`, `Realtime_Core | Connection established`, bucket `getUpdates` requests, and `User settings loaded` are normal startup flow.
- `getUpdates TOO_LONG ... startSeq=0` is expected on a fresh DB when the server says the local sequence is too old. Current cold-start behavior fast-forwards that bucket.
- `nw_protocol_socket_set_no_wake_from_sleep ... Invalid argument` is Apple networking noise.
- The SwiftUI `DynamicBody` / `TabView` stack fragment is not actionable by itself. If this was from a hang report, the omitted earlier frames are the important part.

## Data Correctness Bugs

The SQLite foreign-key failures are real correctness bugs, not harmless noise.

`apple/InlineKit/Sources/InlineKit/Transactions2/GetChatsTransaction.swift`

- `GetChatsTransaction` saves spaces, users, chats, messages, and dialogs manually.
- It catches row-level save errors and keeps going.
- It only strips `lastMsgId` before the first chat save.
- It does not sanitize other optional foreign keys such as `spaceId`, `createdBy`, `peerUserId`, `parentChatId`, message sender/peer refs, or dialog `chatId` / `peerThreadId`.

Relevant path:

- `GetChatsTransaction.apply`: chat save around lines 62-72.
- message save around lines 76-81.
- dialog save around lines 96-101.

`apple/InlineKit/Sources/InlineKit/Models/Message.swift`

- `Message.save` defaults `materializeMissingReferences` to `false`.
- Fresh catch-up update application passes `true`, but `GetChatsTransaction` does not.
- The helper can create minimal local users/chats for message refs when enabled.

Relevant path:

- `Message.save(... materializeMissingReferences:)` around lines 910-918.
- `ensureLocalReferences` around lines 1017-1098.

`apple/InlineKit/Sources/InlineKit/Models/Dialog.swift`

- `Dialog.saveFull` only clears a missing `spaceId`.
- It does not clear or materialize missing `chatId`, `peerThreadId`, or `peerUserId`.

Relevant path:

- `Dialog.clearMissingOptionalReferences` around lines 410-414.

`apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift`

- `UpdateNewChat.apply` logs failed user/chat/dialog saves but swallows the errors.
- The outer update engine can then return success and advance sync sequence even though rows were not persisted.

Relevant paths:

- `UpdateNewChat.apply` around lines 785-810.
- outer `apply(update:)` returns `true` after the switch around line 157.

## Hang / Wedge Bug

`SWIFT TASK CONTINUATION MISUSE: sendPing(fastTimeout:) leaked its continuation without resuming it` is a real bug.

`apple/InlineKit/Sources/InlineKit/RealtimeAPI/WebSocketTransport.swift`

- `sendPing` races a timeout task against `URLSessionWebSocketTask.sendPing`.
- If the timeout wins, `hasCompleted` becomes true and the ping callback later refuses to resume the checked continuation.
- The task group cancels the ping task, but `withCheckedThrowingContinuation` has no cancellation resume path.
- This can suspend realtime health checks forever.

Relevant path:

- `sendPing(fastTimeout:)` around lines 496-545.

## Lower-Priority Noise

Sentry is intentionally disabled in debug builds, but logger/realtime paths still call Sentry APIs:

- `Analytics.start()` exits early in debug because `runInDebugBuilds = false`.
- `Logger`, `PerformanceTrace`, and realtime transport breadcrumb code still call Sentry.

This is not the data-load failure, but it creates noisy fatal SDK logs and should be guarded.

`fopen failed... Invalidating cache` looks like system cache noise unless paired with missing media/render failures.

## Likely Root Cause

Fresh startup is receiving partial or out-of-order entities. Some paths are robust to that, especially sync catch-up message application with sidecars and `materializeMissingReferences: true`. `GetChatsTransaction` and `UpdateNewChat.apply` are not equally robust.

The log pattern fits this:

1. Initial `getChats` persistence tries to insert chats/messages/dialogs.
2. Foreign-key failures reject rows.
3. Later chat bucket sync/realtime updates insert sidecars/placeholders and some data recovers.
4. Since some failures are swallowed, sync state may still advance over writes that did not land.

## Priority Fixes

1. Fix `sendPing` so every continuation is resumed exactly once on success, error, timeout, and cancellation.
2. Make fresh-DB persistence dependency-safe:
   - Use shared chat save logic that clears or materializes optional refs consistently.
   - Use `Message.save(... materializeMissingReferences: true)` in `GetChatsTransaction`.
   - Extend dialog reference handling for missing `chatId`, `peerThreadId`, and `peerUserId`.
   - Stop swallowing DB persistence failures for sync-applied updates that advance sequence.
3. Add a fresh DB regression test for `getChats` with:
   - thread chats in a space,
   - `createdBy`,
   - messages,
   - dialogs,
   - missing or out-of-order referenced rows.
4. Guard Sentry calls when analytics is intentionally disabled.

## Security / Performance / Production Readiness

- Security: no direct security issue found in the provided logs.
- Performance: repeated FK failures and recovery syncs can add startup latency and extra DB work.
- Production readiness: not ready. The FK failures can leave partial local state, and the ping continuation leak can hang realtime connection health.
