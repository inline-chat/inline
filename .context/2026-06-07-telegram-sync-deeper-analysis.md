# Telegram-Informed Sync Reliability Analysis

Date: 2026-06-07

Scope: compare Telegram's local sync architecture with Inline's current RealtimeV2 buckets, then identify speed, reliability, and correctness improvements for a production work chat app.

No code changes were made.

## Telegram Patterns Worth Copying

Telegram does not treat "server says there are updates" as equivalent to "local state is caught up." It has authoritative cursors (`pts`, `qts`, `seq`, `date`) and per-channel `pts`, but those cursors only become committed local state after update replay succeeds.

Key refs:

- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/UpdateGroup.swift:5`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/AccountStateManager.swift:858`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/AccountStateManager.swift:897`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift:3720`

Telegram detects holes explicitly. For account updates, `pts/qts/seq` ranges are sorted and only applied when they match the expected previous state. When a hole appears, it marks the final state incomplete and falls back to a difference poll rather than advancing over the gap.

Key refs:

- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift:579`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift:586`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift:625`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/AccountStateManager.swift:1069`

Telegram validates replay before committing. It verifies required peers exist and that the transaction's starting account/channel state still matches the replay input. If verification fails, replay returns nil and the manager schedules a difference poll instead of pretending success.

Key refs:

- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift:3546`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift:3575`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift:3591`

Telegram treats chat list and message history holes as first-class local state. There are hole tables/views and managers that fetch holes in bounded background work. Sidebar/list correctness is not inferred only from a last-message pointer.

Key refs:

- `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/ChatListTable.swift:43`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/ChatListTable.swift:172`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/ManagedChatListHoles.swift:39`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/ManagedMessageHistoryHoles.swift:144`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/Holes.swift:413`

Telegram's dialog fetch returns a full sidebar row bundle: peers, notification settings, read states, channel states, top message ids, top messages, tag summaries, and lower-bound hole position.

Key refs:

- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/FetchChatList.swift:13`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/FetchChatList.swift:50`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/Holes.swift:1102`

TDLib shows the same invariant at lower level: pending/postponed queues for `pts`, `qts`, and `seq`, timers for unfilled gaps, and forced `getDifference` when a gap cannot be repaired opportunistically.

Key refs:

- `/Users/mo/dev/telegram/td/td/telegram/UpdatesManager.h:272`
- `/Users/mo/dev/telegram/td/td/telegram/UpdatesManager.cpp:334`
- `/Users/mo/dev/telegram/td/td/telegram/UpdatesManager.cpp:3425`
- `/Users/mo/dev/telegram/td/td/telegram/UpdatesManager.cpp:3483`

## Inline Gaps By Invariant

### 1. Discovery Cursor Is Not Completion State

Inline `getUpdatesState` pushes `chatHasNewUpdates` / `spaceHasNewUpdates` hints and returns a date. The Apple client persists that date immediately after the RPC result, before the hinted buckets have necessarily completed.

Key refs:

- `server/src/functions/updates.getUpdatesState.ts:93`
- `server/src/functions/updates.getUpdatesState.ts:149`
- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:376`
- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:384`

Impact: a global scan can stop re-discovering buckets even when a bucket failed, fast-forwarded, or got stuck on non-progress.

### 2. Missing Rows Are Safe But Not Repairable

The server now only delivers the contiguous inflated prefix. This prevents clients from advancing over a missing update. But when a row references a missing message, the server drops that inflated update and the client sees non-progress.

Key refs:

- `server/src/modules/updates/sync.ts:268`
- `server/src/modules/updates/sync.ts:292`
- `server/src/functions/updates.getUpdates.ts:150`
- `server/src/functions/updates.getUpdates.ts:239`
- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:1165`

Impact: this is exactly the `Sync Skipping editMessage update due to missing message` production pattern. It avoids silent loss, but creates permanent bucket debt.

### 3. Cold `TOO_LONG` Can Mark Message Buckets Complete Without Messages

On cold start, a bucket that receives `TOO_LONG` fast-forwards to the target seq and clears pending updates. The current tests explicitly assert this.

Key refs:

- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:1097`
- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:1207`
- `apple/InlineKit/Tests/InlineKitTests/RealtimeV2/SyncTests.swift:423`

Impact: inactive/cold chats can appear caught up while never receiving the message rows that make sidebar/history correct.

### 4. Update Writers Can Produce Invalid References

The edit path inserts the update row before updating the message, and the message update uses the global `db` handle instead of the transaction handle. If no message row is updated, the transaction can still return and commit the update row before throwing after the transaction.

Key refs:

- `server/src/db/models/messages.ts:690`
- `server/src/db/models/messages.ts:703`
- `server/src/db/models/messages.ts:746`
- `server/src/db/models/messages.ts:767`

The reply-count/subthread parent update path emits an `editMessage` update for the parent without verifying the parent message row exists.

Key ref:

- `server/src/modules/subthreads.ts:376`

Impact: server logs can be caused by real write-path corruption, not only old data.

### 5. Catch-Up Sidecars Are Too Thin For Sidebar Correctness

Chat catch-up sidecars include users/chats/spaces, but explicitly return an empty dialogs array.

Key ref:

- `server/src/modules/updates/sync.ts:593`

Apple can apply dialogs from sidecars if present, but they are absent.

Key ref:

- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift:320`

Impact: sidebar state can remain wrong after catch-up, especially after resets or missed message rows.

### 6. Local Apply Can Lie

The outer Apple batch returns failure when an update applicator throws. But several applicators catch/log internal DB errors and do not rethrow, so the outer batch can count them as applied and allow bucket seq advancement.

Key refs:

- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift:14`
- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift:168`
- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift:825`
- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift:1244`

Sync cursor storage also logs and swallows failures.

Key refs:

- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/GRDBSyncStorage.swift:57`
- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/GRDBSyncStorage.swift:88`
- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/GRDBSyncStorage.swift:119`

Impact: local state can diverge while sync metadata says it is caught up.

### 7. Last Message Is A Denormalized Invariant Without A Snapshot Repair Loop

`Chat.saveWithValidLastMsg` clears `lastMsgId` when the referenced message is not present locally. `Chat.updateLastMsgId` only advances when the local joined last-message state allows it.

Key refs:

- `apple/InlineKit/Sources/InlineKit/Models/Chat.swift:270`
- `apple/InlineKit/Sources/InlineKit/Models/Chat.swift:368`

Opening chats repairs via direct `getChat` / `getChatHistory` paths, but cached chat opens now skip `getChat` and only fetch history/user.

Key refs:

- `apple/InlineKit/Sources/InlineKit/ViewModels/FullChat.swift:390`
- `apple/InlineKit/Sources/InlineKit/Transactions2/GetChatTransaction.swift:48`
- `apple/InlineKit/Sources/InlineKit/Transactions2/GetChatHistoryTransaction.swift:51`

Impact: last-message correctness depends on opening individual chats or receiving a complete catch-up snapshot, and catch-up does not currently guarantee one.

## Production Fix Plan

### Phase 0: Stop Current Data Loss Modes

1. Remove cold `TOO_LONG` fast-forward for chat buckets that can contain message rows.
   - Replace with bounded snapshot fetch or durable repair debt.
   - Keep fast-forward only for bucket types/update classes where no user-visible state is lost.

2. Fix invalid update writers.
   - Edit message inside the same transaction handle.
   - Verify the target message before inserting `editMessage` update rows.
   - Make subthread reply-count update verify the parent message first or emit a repairable tombstone.

3. Make missing-message rows repairable.
   - Server should return an explicit repair status, skip/tombstone update, or snapshot response for the blocking seq.
   - The client should not retry forever with identical non-progress responses.

### Phase 1: Make Catch-Up Transactionally Honest

4. Split global discovery from completion.
   - Persist pending bucket hints discovered by `getUpdatesState`.
   - Advance global scan date only after all hinted buckets are completed or stored as durable repair debt.
   - Alternatively, change `getUpdatesState` to return changed bucket ids and an opaque cursor that is acked after completion.

5. Make apply errors fatal for cursor advancement.
   - Update applicators should rethrow DB failures that affect local correctness.
   - Cursor writes should report failure to the sync actor instead of swallowing errors.
   - Add a replay verification step for required sidecars/message refs before bucket seq commit.

6. Expand chat catch-up sidecars into a real chat snapshot.
   - Include dialog row, chat row, top/last message, read state, and peer/user/space rows for each affected chat.
   - Treat this as the source of truth for sidebar rows, similar to Telegram dialog fetch.

### Phase 2: Add Lightweight Hole/Repair Infrastructure

7. Add local repair tables.
   - `sync_bucket_pending`: bucket key, target seq, source cursor/date, first seen, attempts, error.
   - `chat_snapshot_holes`: peer/chat, reason, needed last message id/range, attempts.
   - Keep bounded workers and backoff; do not full-sync everything.

8. Add server repair endpoints/RPCs.
   - `getChatSnapshot(peer)` for sidebar correctness.
   - `getBucketRepair(bucket, startSeq)` or extend `getUpdates` with `repair` result type.
   - Preserve sequenced invariants: repair result either reconstructs seq N or emits an explicit seq-N tombstone.

9. Add list correctness observations.
   - Sidebar should be able to show/refresh from durable chat snapshot state, not only implicit `lastMsgId -> Message` joins.
   - Add telemetry for missing local last message, dialog without chat, chat without dialog, and bucket debt age.

### Phase 3: Speed And Load Control

10. Keep bounded concurrency, but prioritize visible chats and sidebar snapshots.
    - Active chat history first.
    - Sidebar top N snapshots next.
    - Background bucket repair after.

11. Batch by snapshot, not by raw update count only.
    - For cold start, fetching 50 arbitrary update rows is less useful than fetching "top chat list state + active chat history window."

12. Add repair observability.
    - Metrics: non-progress count, bucket debt age, missing-message row count, repair success/failure, fast-forward count by bucket/update class, local apply failure by type.
    - Sentry breadcrumbs should include bucket key, local seq, server seq, result type, and whether a repair was queued.

## Tests That Need To Change

- Replace `cold start TOO_LONG fast-forwards without looping` with a test that asserts chat buckets queue repair or fetch a snapshot before advancing.
- Extend server missing-message tests to assert a repair/tombstone path, not only `seq` non-advance.
- Add Apple tests where local DB apply fails and bucket seq does not advance.
- Add iOS/sidebar integration tests for:
  - missing local last message after catch-up;
  - global reconnect catch-up loads all changed chat snapshots without opening chats;
  - inactive chat receives enough state for correct last-message display;
  - non-progress response creates durable repair debt and does not disappear after restart.

