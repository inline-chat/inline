# Sync Deep Audit Beyond First Pass

Date: 2026-06-07

Scope: investigation only. No implementation changes. This pass reviews server update writers, update log invariants, getUpdates/getUpdatesState behavior, Apple bucket sync, local DB persistence, iOS active-chat publishing, recent commits, and Telegram's sync model.

Correction after user context: the provided `Skipping editMessage update due to missing message` log should not be treated as strong evidence of a bad server writer or the main incident root cause. The user confirmed the edited message had already been deleted. That makes the log much less important: it is either expected/skippable deleted-target behavior or a secondary protocol semantics issue, not proof that chat saving/refetching was broken.

## Executive Answer

The updating stage was not globally disabled. `SyncConfig.default` still enables message updates, and the default API wiring uses `GRDBSyncStorage`.

But the visible "updating" state can easily be absent. Apple only marks sync activity active while bucket fetches are in flight, not while `getUpdatesState` is running, and the displayed connection state is delayed. If catch-up stalls quickly, returns a fast non-progress response, or fast-forwards a cold bucket, the user can see no updating state.

The iOS active-chat gate is a real regression risk. It suppresses message list publish events for inactive chats, and the recovery reload is sent through a `PassthroughSubject` when the chat becomes active. If activation happens before the message view model subscribes, the reload can be dropped. This fits "I had to open chats one by one" because direct open fetches repair local rows and emit reloads.

The server logs should not be the center of this report. Given the deleted-message context, they are not a good explanation for why iOS catch-up, chat loading, updating state, and last-message state regressed. At most, they show that the sync protocol needs a clean way to represent obsolete/deleted-target updates so they do not become confusing warnings or bucket stalls.

There are several independent bugs that can produce "messages did not catch up", "last message was wrong", and "sidebar/chats only fixed after opening":

- `getUpdates` has a good "do not advance over missing data" guard, but no repair/skip semantics for legitimate obsolete updates.
- Cold-start `TOO_LONG` fast-forwards a bucket without fetching messages.
- `getUpdatesState` advances the global date independently of bucket completion.
- Apple update apply methods often swallow local DB failures, so sync can advance after partial persistence.
- Chat sidecars omit dialogs, and Apple clears `lastMsgId` when the last message is not locally present.
- iOS active-chat gating suppresses inactive message-list updates and relies on a non-durable reload event.
- Server writer invariants are still worth tightening, but the provided edit log should not be used as the proof.

## Correctness Invariants

These are the invariants the system needs for reliable chat sync:

1. Every update row must reference data that is durable and visible in the same committed transaction.
2. Bucket seq must be allocated atomically and monotonically from the committed bucket state, not from a stale caller object.
3. A client may only advance a bucket cursor after all updates up to that cursor were applied durably, or after an explicit server-authored skip/tombstone with clear semantics.
4. A client may only advance global discovery state when discovered bucket work is either complete or recorded as durable repair debt.
5. Catch-up bundles for chat list/sidebar state must include the full row bundle needed to render correct chat, dialog, last message, parent, sender, and space state.
6. UI publish gating must never be the only recovery path. Local DB state and durable dirty markers must drive eventual UI correctness.
7. Sync errors must be observable as bucket holes/repair debt, not hidden as warn logs and retry backoff.

## Root Causes

### 1. Cold-start TOO_LONG intentionally drops catch-up messages

On Apple, a cold bucket means `seq == 0 || date == 0`. If `getUpdates` returns `TOO_LONG`, the client sets the bucket state to the upper bound and applies nothing.

Reference: `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:1207`.

The test explicitly asserts this behavior:

Reference: `apple/InlineKit/Tests/InlineKitTests/RealtimeV2/SyncTests.swift:423`.

This avoids large first-run downloads, but it means a chat bucket can be marked caught up without loading the missing messages. The only reliable repair path is direct open/history fetch. That fits "catch-up did not load all messages" and "I had to open chats one by one".

### 2. Global discovery date advances outside bucket success

After `getUpdatesState`, Apple updates `lastSyncDate` from the payload date immediately.

Reference: `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:376`.

Server `getUpdatesState` returns `now` for `date == 0`, and also advances to `now` when no changed chats/spaces are found.

Reference: `server/src/functions/updates.getUpdatesState.ts:26`.
Reference: `server/src/functions/updates.getUpdatesState.ts:73`.

That is efficient, but it makes the global cursor independent from whether all pushed bucket fetches actually completed. If a bucket is stalled, skipped, or fast-forwarded on cold start, future discovery may not revisit it unless new updates change `lastUpdateDate` again.

### 3. Apple apply paths swallow DB failures

The sync wrapper can avoid advancing when `applyUpdates` reports failure, and there are tests for that. The issue is that many per-update `apply` methods catch errors internally and return success to the wrapper.

Examples:

- `UpdateNewChat.apply` catches user/chat/dialog save errors and does not throw.
- `UpdateDeleteMessages.apply` returns when chat is missing and catches delete failures.
- `UpdateMessageAttachment.apply` logs and returns when the message is missing.
- `UpdateChatVisibility`, `UpdateChatInfo`, and `UpdateChatMoved` catch and do not throw.

References:

- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift:617`
- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift:670`
- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift:825`
- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift:1095`

This can create local drift even when server sync is correct: the client advances the bucket after a partial/no-op local write, then later only a direct refetch repairs the state.

### 4. iOS active-chat publisher gate can drop recovery reloads

On iOS, `MessagesPublisher.shouldPublish(peer:)` only returns true for active chats. `activateChat(peer:)` sends a `.reload` if the peer was inactive.

Reference: `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift:1071`.

The publisher is a `PassthroughSubject`, so that reload is not durable. If SwiftUI activates the chat before the progressive view model subscribes, the only recovery event can be dropped.

There is also a separate data-source correctness issue: `.add` returns `indexSet: [messages.count - 1]` even when multiple messages were inserted, and even when reversed insertion put them at index 0.

Reference: `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift:258`.

That can cause visible list inconsistencies during burst delivery.

### 5. Server editMessage write ordering is a code risk, not the incident center

`server/src/db/models/messages.ts` writes the edit update before verifying the message update affected a row:

- It locks the chat.
- It inserts an `editMessage` update.
- It updates the message using global `db.update(messages)` instead of the transaction `tx.update(messages)`.
- It updates chat `updateSeq` and `lastUpdateDate`.
- It returns `message: msgs[0]`.
- It checks `if (!message)` only after the transaction commits.

Reference: `server/src/db/models/messages.ts:703`.

This can commit an update row and chat cursor that point at a missing message, then throw. That is still a real invariant risk and should be fixed. But the provided production log should not be used as evidence for this, because the user confirmed that specific edited message had already been deleted.

### 6. Reply-thread parent summary updates need validation, but the log does not prove they caused this incident

`persistMessageRepliesUpdate` writes an `editMessage` update for the parent chat/message, but it only verifies and locks the parent chat. It does not verify that `parentMessageId` exists before inserting the update.

Reference: `server/src/modules/subthreads.ts:376`.

`messages.sendMessage` calls this on every send in a reply thread:

Reference: `server/src/functions/messages.sendMessage.ts:411`.

This is still a writer invariant gap. However, after the deleted-edit clarification, it should be treated as a code risk to test and harden, not as the main explanation for the user's iOS catch-up failure.

### 7. Missing or obsolete required messages can create permanent non-progress

The hardening in `getUpdates` was directionally correct: it refuses to deliver seq N+1 if seq N cannot inflate. That prevents silent data loss.

Reference: `server/src/functions/updates.getUpdates.ts:150`.

But `processChatUpdates` drops `newMessage`/`editMessage` updates whose required message is missing:

Reference: `server/src/modules/updates/sync.ts:270`.

Then `selectContiguousDelivery` returns the last contiguous seq. If the first missing update is next after the client's cursor, the server returns no updates, unchanged seq, `final=false`, and no sidecars.

Reference: `server/src/functions/updates.getUpdates.ts:238`.

Apple treats that as non-progress and stops spinning, which is good for CPU but bad for recovery. If the missing message was legitimately deleted, this should be a skippable obsolete update or tombstone. The problem is missing protocol semantics, not necessarily corrupt data.

The server test now asserts this non-advance behavior:

Reference: `server/src/__tests__/functions/updates.getUpdates.test.ts:242`.

The missing piece is a test and protocol for what happens next.

### 8. Chat/space seq allocation is fragile

The generic `insertUpdate` computes `seq = (entity.updateSeq ?? 0) + 1` from the object passed by the caller.

Reference: `server/src/db/models/updates.ts:62`.

This is only safe if every writer locks a fresh row, writes exactly one update for that entity in the transaction, and then updates `updateSeq`/`lastUpdateDate` from the inserted update. That discipline is easy to violate.

The user bucket implementation is safer. It atomically advances `users.updateSeq` using the max of the stored user counter and existing update rows before inserting the user update. The tests cover stale/null counters and concurrency.

Reference: `server/src/__tests__/modules/userBucketUpdates.test.ts:85`.

Chat and space buckets should use the same allocator shape.

### 9. Sidecars do not include dialogs

Chat catch-up sidecars currently return users, chats, and spaces, but `dialogs: []`.

Reference: `server/src/modules/updates/sync.ts:593`.

The server test asserts empty dialogs in sidecars.

Reference: `server/src/__tests__/functions/updates.getUpdates.test.ts:468`.

That means catch-up can have enough data to save a message but not enough data to fully repair the chat list/sidebar row. Direct chat/dialog fetches can repair it later, which matches the observed "opening chats fixed them" behavior.

### 10. Apple sync state storage failures are also swallowed

`GRDBSyncStorage.setState`, `setBucketState`, `removeBucketState`, and `setBucketStates` catch and log errors but return `Void`.

Reference: `apple/InlineKit/Sources/InlineKit/RealtimeAPI/GRDBSyncStorage.swift:57`.

The sync actor cannot know that a cursor write failed. On next launch, it may replay too much or too little depending on what actually persisted.

### 11. `lastMsgId` is intentionally cleared when the message is missing

`Chat.saveWithValidLastMsg` clears `lastMsgId` if the referenced message is not present locally.

Reference: `apple/InlineKit/Sources/InlineKit/Models/Chat.swift:270`.

This protects local foreign-key integrity, but it also explains wrong/empty sidebar last-message state after catch-up sidecars or chat-list fetches that do not include the last message row. It is a symptom amplifier: once messages are missing, chat rows become less informative.

### 12. Direct open repairs because it fetches full bundles

`GetChatTransaction` saves chat/dialog and optionally the anchor. `GetChatHistoryTransaction` saves returned messages and updates chat last message ids, then emits a reload.

References:

- `apple/InlineKit/Sources/InlineKit/Transactions2/GetChatTransaction.swift:48`
- `apple/InlineKit/Sources/InlineKit/Transactions2/GetChatHistoryTransaction.swift:61`

That is why manually opening a chat repairs state one chat at a time. The repair is not coming from catch-up; it is coming from direct RPCs with fuller data.

### 13. `getUpdatesState` may miss linked subthreads without dialogs

`ChatModel.getUserChats` includes linked subthreads only once a dialog exists for that user.

Reference: `server/src/db/models/chats.ts:372`.

If a linked reply-thread bucket has updates but no dialog yet, global catch-up may not discover it. Opening/following can create a dialog and make it discoverable later.

## Recent Commit Assessment

Relevant commits in the past week:

- `3144efa9 sync: harden catch-up updates`
- `31020b07 ios: gate message updates to active chat`
- `cbdddd5a server: sync participant adds`
- `e2e1b42f server: cache and sync url previews`
- `c7100b5a client: add clear history support`
- `fead7c69 server: add clear history backend`
- `4fc4dd90 apple: preload reply thread metadata`
- `51b8bee3 apple: add reply thread follow controls`
- `678a92a9 server: add reply thread follow mode`

The highest-risk regression pair is:

1. `3144efa9` made catch-up refuse to advance over missing inflated data. This prevents silent loss, but it can expose missing/obsolete references as permanent stalls unless the server returns an explicit skip or repair state.
2. `31020b07` suppressed inactive iOS message-list publishing. That can hide updates until direct open, and the activation reload is not durable.

The reply-thread/follow-mode commits are relevant to audit because they add more update traffic and linked-thread state, but the provided deleted-edit log should not be used as proof that they caused the incident.

Clear-history and URL-preview updates expand the update surface and should be included in invariant tests, but the production log pattern points more strongly at reply-thread parent summary updates or `editMessage`.

## Telegram Comparison

Telegram's model is stricter around holes:

- It maintains account-level `pts/qts/seq/date` and channel-level `pts`.
- It buffers skipped updates and only advances the known-good point after contiguous replay.
- It requests difference/channel-difference for gaps instead of silently fast-forwarding normal message state.
- It treats history invalidation/holes as explicit state that visible views can validate and repair.

Local references:

- `/Users/mo/dev/telegram/tdesktop/Telegram/SourceFiles/data/data_pts_waiter.cpp:170`
- `/Users/mo/dev/telegram/tdesktop/Telegram/SourceFiles/api/api_updates.cpp:398`
- `/Users/mo/dev/telegram/tdesktop/Telegram/SourceFiles/api/api_updates.cpp:631`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/AccountStateManager.swift:1470`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/HistoryViewStateValidation.swift:29`

The important lesson is not to copy Telegram's exact schema. The lesson is that "hole" is a first-class state. Inline currently has two weak alternatives: skip/fast-forward for cold buckets, or non-progress retry for missing/obsolete refs. Neither gives the product a durable, observable, repairable sync state.

## Production Fix Plan

### Phase 0: Re-center production diagnosis and inspect data

1. Do not treat the provided `editMessage` missing-message log as the main cause. Classify it as deleted-target/obsolete-update behavior unless production data proves otherwise.
2. Add a server-side audit job or admin-only command that decrypts update rows through existing `UpdatesModel` helpers and verifies every update's referenced rows exist, without logging sensitive payload contents.
3. Report uninflatable rows by bucket, entity id, seq, update type, missing ref, age, and whether the missing ref was legitimately deleted.
4. Fix server writer invariant risks separately from the iOS catch-up incident:
   - In `editMessage`, verify the target message inside the transaction before inserting an update, use the same transaction for the message update, and throw before writing update rows.
   - In `persistMessageRepliesUpdate`, verify the parent message exists before inserting the parent summary update. If missing, do not enqueue an `editMessage`; record a repair metric and return a typed no-op/repair result.
5. Decide protocol behavior for existing obsolete/missing-target rows:
   - If the referenced message can be restored from canonical history, restore it.
   - If it was legitimately deleted/cleared, represent it as an explicit tombstone/skip update or add a server-authored repair marker that lets clients advance without pretending the edit happened.
   - Do not ask clients to blindly advance over unknown missing message updates.

### Phase 1: Make server update writes invariant-safe

1. Replace raw chat/space `UpdatesModel.insertUpdate` call sites with per-bucket helpers similar to `UserBucketUpdates.enqueue`.
2. Make the helper allocate seq atomically from the database, not from a caller-provided entity object.
3. Make the helper own the entity `updateSeq`/`lastUpdateDate` update in the same transaction.
4. For every update type, require a typed reference validation step before inserting the update.
5. Keep payload side effects and update rows in one transaction where possible. `messages.sendMessage` currently acknowledges this gap around attachments and message/update coupling.
6. Add invariant tests:
   - Every writer creates no update if required references are missing.
   - Concurrent writes do not duplicate seq.
   - `chats.updateSeq`/`spaces.updateSeq` never lag behind max update row.
   - Inflating all rows written by the writer succeeds immediately after commit.

### Phase 2: Add an explicit repair protocol to getUpdates

1. Add a protocol result for bucket holes, for example `REPAIR_REQUIRED`, carrying bucket, seq, update type, and a safe repair action.
2. Alternatively emit typed skip/tombstone updates only when the server can prove the original update is obsolete and safe to skip.
3. Make `TOO_LONG` return either a bounded snapshot bundle or require a full bucket resync. Do not cold-fast-forward message buckets without a durable "history not loaded" state.
4. Persist bucket repair debt on the client. A bucket with unresolved repair debt should remain discoverable even if global `lastSyncDate` advances.
5. Expose retry age and repair state in logs/Sentry/metrics.

### Phase 3: Make Apple persistence transactional and honest

1. Update apply methods so real DB failures throw and are reflected in `UpdateApplyResult.failedCount`.
2. Only swallow errors for explicitly safe no-ops, and encode those as applied/skipped with reason.
3. Make sync state storage methods return success/failure or throw. The sync actor should not assume a cursor was saved.
4. Save sidecars and updates in a single local transaction per chunk, then advance bucket state only after that transaction commits.
5. Include dialogs in chat catch-up sidecars or introduce a complete `ChatListRow`/`DialogBundle` sidecar for sidebar correctness.
6. Add local consistency checks after apply:
   - chat `lastMsgId` points to an existing message or has a pending last-message repair marker.
   - dialog references an existing chat.
   - message attachments reference existing messages.

### Phase 4: Fix iOS UI recovery semantics

1. Keep active-chat gating if needed for performance, but make skipped inactive updates mark the peer dirty durably in memory and/or DB.
2. Replace activation reload as a one-shot `PassthroughSubject` event with a model-driven reload:
   - On view model init, if peer is active or dirty, load from DB immediately.
   - On activation, set dirty/reload state that late subscribers can observe.
3. Fix multi-message add change sets so index sets match actual inserted ranges for normal and reversed lists.
4. Ensure sidebar/chat-list views are driven by DB observations, not message-list publisher events.
5. Add an iOS regression test for inactive-chat catch-up followed by opening the chat after the reload event would otherwise have been dropped.

### Phase 5: Observability and operational controls

Add metrics/events for:

- uninflatable updates by bucket/type/entity/seq
- non-progress getUpdates responses by bucket and age
- buckets with unresolved repair debt
- cold-start `TOO_LONG` fast-forwards
- local apply failures by update type
- local cursor save failures
- sidecar missing-dialog repair rates
- direct-open repairs that changed last message or inserted missing messages

Sentry CLI note: Sentry access was attempted earlier in this investigation, but project listing returned no projects and org listing returned `403 Forbidden`. That means this pass is based on code and provided logs, not fresh Sentry event inspection.

## Test Plan Needed For The Rewrite

Server:

- `editMessage` missing target does not write update row or advance chat seq.
- reply-thread parent missing does not write parent `editMessage`.
- every chat/space writer uses atomic seq allocator and survives concurrent writes.
- `getUpdates` reports explicit repair state for missing required refs.
- `TOO_LONG` does not cause invisible message loss.
- sidecars include the full sidebar/dialog bundle needed by clients.

Apple sync:

- bucket state does not advance if any per-update local apply fails.
- global sync date does not make unresolved bucket repair debt undiscoverable.
- cold bucket over limit creates snapshot/repair state, not silent fast-forward.
- sync state persistence failure is surfaced and retried.

iOS UI:

- inactive chat receives catch-up updates, then opening the chat loads the DB even if activation fired before subscription.
- multi-message burst adds produce correct index sets.
- sidebar last message updates after catch-up without direct open.

End-to-end:

- offline iOS device receives many messages across many chats, reconnects, shows updating/catch-up status, sidebar last messages are correct, and opening a chat does not reveal missing messages.
- reply-thread parent deleted/cleared plus new child messages does not permanently stall the parent bucket.
- production-like obsolete/deleted-target update fixture creates a visible repair or skip state and can be recovered without data loss.

## Production Readiness

Not production-ready as-is for reliable work-chat sync. The current system can avoid silent seq advancement over missing required server data, but it can also stall permanently and has no first-class repair path. Separately, Apple can still advance after swallowed local DB apply failures, and iOS UI gating can hide updates until direct chat open.

Security risk from this investigation: no new secret exposure found. The production audit job must not log decrypted message bodies or sensitive payload data; it should log only ids, update type, seq, bucket, and missing reference class.

Performance risk: making sidecars complete and seq allocation atomic can add DB work. Keep pages bounded, index update lookups by `(bucket, entity_id, seq)`, batch sidecar loads, and measure send-message/open-chat latency because those paths are explicitly latency critical.

The reliable design direction is: atomic server writers, explicit holes/repair debt, complete local bundles, honest apply failures, durable UI dirty/reload state, and production metrics for every stalled bucket.
