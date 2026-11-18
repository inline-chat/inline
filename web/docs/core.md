# The account core

The core is the authority on the device: connection, sync, the SQLite replica, the outbox, and the queries the UI subscribes to. Today it is `web/packages/client`. Read this before changing anything in it, and before adding a feature that needs new data or a new action.

The native clients are the reference. The Swift engine is in `apple/InlineKit/Sources/RealtimeV2` (`Sync/Sync.swift`, `Transaction/Transactions.swift`, `Connection/ConnectionManager.swift`), and a side-effect-free version of the same logic is in `apple/InlineRealtimeCore`. The sync protocol is documented in `landing/src/docs/content/technical/sync.md` and `sync-recovery.md`. When the web core and the Swift engine disagree on semantics, the Swift engine is right until shown otherwise.

## Invariants

Each of these is a test, not a guideline. Do not land a change that breaks one.

1. Updates, their sidecars, history coverage and the bucket position commit in one SQLite transaction. Nothing is published before the commit.
2. An intent and its optimistic rows commit together before the request is sent. The client random ID is stable across retries, reloads and uncertainty. Only replay-safe intents are restored after a restart.
3. Local, sent, acknowledged, rejected and uncertain are distinct states. An uncertain send is never shown as failed or as delivered.
4. An edit keeps a confirmed base and ordered intents. The displayed value is recomputed from them, never undone.
5. Certified history ranges are tracked apart from cached rows. A stored row does not close a hole. While connected, a window shows only contiguous certified history, and read state never advances across a hole.
6. One writer per account, one ordered write queue.
7. Unknown or unsupported updates are stored for replay, never dropped.
8. Every patch to the UI names its base revision. A gap triggers a snapshot resync.
9. A replica written by a newer schema stops on an "outdated" phase. An older build never opens it and never becomes the writer.
10. Sign-out and server revocation close the core and erase the replica. The erase is marked before it starts, and a replica left marked is erased before anything opens it again.
11. Network work never runs inside a SQLite transaction and never blocks a local read.
12. 64-bit IDs are never coerced through a JavaScript `number`. They are branded strings from `ids` in memory and `bigint` on the wire.
13. A read from disk that started before a write was accepted never overwrites that write's result in memory.

Where the code stands against them today is in the last section.

## Shape

- **State machines that return effects.** Connection, sync and outbox logic take events and return what to do: send, start a timer, write. A thin interpreter performs the effects. Tests drive the machines with a virtual clock and a scripted transport, so reconnect, backoff and recovery are deterministic. `apple/InlineRealtimeCore` shows the shape: one `Input`, one batch of `Output`, a next deadline, no hidden async.
- **Runs anywhere.** No DOM, no `window`, no view framework. It runs in a dedicated worker in the browser and directly in Node tests.
- **Decode outside transactions.** Protobuf decoding, validation and any network wait happen before a transaction opens.

## Sync

Durable changes arrive through buckets. There is one user bucket, one per space and one per chat, each with its own sequence.

- If an update's sequence is at or below the cursor, it is a duplicate. If it is the cursor plus one, apply it. If it is further ahead, fence that bucket and fetch the missing range with `getUpdates`.
- A page must account for every sequence through its end: delivered, or listed as skipped with a reason.
- `TOO_LONG` and "snapshot repair required" mean the bucket's materialized state must be replaced by an authoritative snapshot. This must exist for all three bucket kinds. A bucket that cannot be repaired must end in a visible state, not an endless retry.
- Discovery after a reconnect uses `getUpdatesState` with the saved date. Persist the new date only after the work it discovered has succeeded.
- Retries back off and are bounded. Every loop that retries has an attempt cap or a terminal state, and a test for it.
- Treat these as distinct recovery conditions with their own handling: a sequence gap, `TOO_LONG`, an unknown update kind, a permission loss, an incompatible schema, a quota failure, corrupt storage.
- Losing access to a chat or space purges it and its descendants in one transaction, keeps drafts, and fences any page or repair still in flight for it.

Typing indicators, presence and compose suggestions are realtime, not sync. They may be lost and are never persisted. Keep the distinction obvious in types and names.

## Outbox

- An intent is a typed, serializable description of something the user did. It has a stable transaction ID.
- Accepting an intent means: write the intent and its optimistic rows in one commit, then send. The UI is told "durably accepted" after the commit, not before.
- Each intent kind declares whether it is safe to replay. Replay-safe intents are restored after a restart and retried. Others that were in flight when the connection dropped settle as "uncertain" and are reconciled against server state.
- When the server ID arrives for a message, the row keeps its identity in the UI.
- Intents that depend on another (a message in a chat that is still being created) wait for it.

## History and windows

- A chat window is a contiguous run of messages plus what is known about its edges ("has older", "at latest").
- Coverage is stored: which ranges of a chat's history the server has certified as complete. An empty page can certify a range. A failed page rolls back rows and coverage together. The Swift reference is `MessageHistoryHole.swift` and `HistoryPageReducer.swift`.
- While connected, older pages come from the server unless the range is certified. Never build a window by stitching cached rows across an uncertified gap.
- A result for a window that has since moved or closed is discarded.

## Queries

The UI subscribes to named queries (see `architecture.md`). For each one the core:

1. Reads the initial result from memory or SQLite.
2. Tracks which rows and lists the subscription depends on.
3. After each commit, recomputes only affected subscriptions, diffs against what the subscriber has, and emits row upserts and list operations in one patch per commit.

Counters such as unread totals are maintained transactionally as projections. They are never recounted per query.

A subscription that is closed releases its rows. A pane closing never cancels an accepted intent.

## Storage

- SQLite WASM in the core's dedicated worker, on the OPFS SAH-pool VFS, one database per account. This VFS needs no cross-origin isolation headers and allows one connection, which matches the one-writer rule.
- **A failed pool installation must never delete or block the replica.** SQLite's default reaction to a failed SAH-pool installation is to remove the pool's directory, and it caches the failure by name. Installation fails whenever another context still holds the access handles, which is the ordinary tab-takeover case. `sqlite/sah-pool-registry.ts` therefore installs one pool per account (and per namespace), always with `preserveOnInitFailure` and `forceReinitIfPreviouslyFailed`, retries briefly while the storage is busy, and then reports `opfs-busy`. A busy or failed pool is never a reason to fall back to memory: that would show an empty app over real data. `eraseOpfsSqliteReplica` removes one account's files and nothing else. `web/lab-storage.html` exercises all of this with contending workers in a real browser; keep it passing, and treat any new code path that can delete the replica as needing a test.
- Migrations are forward-only and tested from every earlier version. Never reset a replica that may hold drafts or pending intents.
- Without OPFS the core runs in memory and the app says that data is not being kept.
- Ask for persistent storage where the browser grants it without a prompt. Eviction would drop unsent intents.
- Storage full is a state: the core stops accepting durable intents and says so.
- Batch large writes. Never seed a bootstrap in one huge transaction, and keep the worker responsive to reads between batches.
- Media bytes live outside SQLite, in OPFS or Cache Storage, under their own budget.
- Local search uses FTS5.

## Retention

Each cached row has a reason to be kept: a pending intent, a pin, an open view, recency. Eviction works against a budget and removes rows whose reasons are gone. It never touches a pending intent or the source bytes of an unsent attachment. Evicting rows also updates coverage, so a hole is known to be a hole.

## Transport

- The V3 secure transport is the target and V2 the fallback, behind one negotiating transport. The portable V3 pieces are in `packages/protocol/src/secure`; the connection in `packages/sdk/src/realtime/v3-connection.ts` currently depends on Node APIs and needs WebSocket, random bytes and decompression injected to run in a browser.
- The connection manager already models network, app activity, wake and backoff as constraints. In the browser these must be fed from real signals (`online`, `visibilitychange`, wake detection) through the `link` layer, since the core has no window.
- The connection reports the client type, version, device ID and time zone.

## Adding a feature end to end

1. Define the row types and the query or intent in `core-protocol`.
2. Implement it in the core: the RPC wrapper, the update handling, the materialization, with tests at the core integration level including the relevant faults.
3. Build the view model on top, with unit tests.
4. Build the view, add it to the UI lab, add the end-to-end test if it is a journey.

If the feature needs a server or protocol change, stop at step 1 and raise it; those need sign-off.

## Where the code stands today

As of 17 November 2026 (evening), measured against the above. Update this list as items close.

**Met, with tests named after the invariant:**

- Invariants 1 and 6: one ordered write queue in `Db`; observers and `subscribeToResidentChanges` are told only after the commit; a storage failure undoes the failed write and everything queued behind it.
- Invariant 5: certified history ranges are persisted (`message_history_coverage`, replica schema version 3), admitted through one reducer in the same commit as the page's rows, and drive the window's edges and `certifiedThrough`.
- A send in an open window: at latest the list gains the send's row in one patch and nothing else moves (no removal, no repeated list) through accept, confirm, rejection, a reconnect and a media send; from older history the window jumps to latest in one replacement (`host/__tests__/send-window.test.ts`). Before 17 November evening the window collapsed to the send alone for a patch and came back as the latest 60 rows, dropping history paged back beyond them, and a send showed above a message of the same second until confirmed (`Db.promoteResidentMessageWindowToLatest`, `queries/compute.ts` window order).
- Durable send identity: a `sendText`'s UI `tx` is a host record (`pending_transaction`, kind `sendTx`, never sent) committed with its outbox entry and shown as `MessageRow.tx` while the send is in the outbox, so a reloaded or handed-off UI matches its overlay row; a `sendMedia`'s `tx` is on its `mediaSend` record. A `tx` or client key re-posted to a later core follows the send to its outcome instead of sending twice.
- Drafts: a send with `draftRevision` deletes the draft in the send's own commit when the draft's revision is at most that (`sendText`: inside the optimistic step; `sendMedia`: inside the record commit). A failed commit keeps both; a newer draft is kept.
- Participants: `addChatParticipants` and `removeChatParticipant` are host records committed with their optimistic grant rows, sent when connected, retried after a lost acknowledgement, resent by the next core, idempotent by `tx` across a restart. A refusal refetches the roster instead of guessing a rollback.
- `chatMedia(chatId, filter)`: local first. The chat's stored matches are read from disk before the first result (`Db.scanChatMessages`, a bounded walk of the `message` primary key: ~5 ms for the first 50 photos of a 100,000-message chat), then server pages (`SEARCH_MESSAGES` with a filter) are committed and listed; `ensure older` continues both. `loading` is the server page only.
- Remote search: `searchServerMessages` (one chat; the server has no cross-chat message search) and `searchUsers` are request and answer, never written to the replica, and fail at once offline.
- Invariant 9: a replica from a newer schema stops on the outdated phase; upgrades are tested from every earlier version.
- Invariant 10: sign-out and revocation stop the core, close the replica and erase it, per account, in this order: the account refuses every intent at once (`CoreResource.signingOut`), an erase marker is written outside the SQLite pool (`accounts/<accountKey>/erase-pending` in the media byte store), `LOG_OUT` is handed to the socket on a sign-out (never awaited, never on a revocation), realtime stops and the replica closes, media and the replica (with its search index) are erased, then the marker goes and `phase` is `signedOut` with `erased: complete` (or `failed`, marker kept). A worker killed after the marker leaves it; the next `session start` of that account, or `CoreHost.finishPendingErase(userId)` at boot, erases before opening (`host/erase.ts`, `sign-out.test.ts`).
- Invariant 13: disk reads reconcile with memory before admitting rows; gated-store tests fail without it.
- Bounded recovery: user and space bucket repairs exist; a bucket that cannot be repaired stops after 8 attempts in a visible stalled state; intent settlement gives up after 8 attempts and reports "uncertain".
- Read frontiers only move forward, wherever they are written.
- The core host (`src/host`) runs one account behind the core protocol: phases, sessions, contexts per UI tab, patches built only from committed state, intents with `accepted` then an outcome. Sidebar rows carry everything a row view needs (last message and sender, draft, follow and notification state); a `newMessages` feed carries live arrivals for notifications; stalled sync is reported in the `core` resource with a retry intent; sign-out tells the server first, with a short timeout.
- Local full-text search and media transfers exist as core modules (`src/search`, `src/media`); see their READMEs for what is and is not wired into the host.
- Storage: one SAH pool per account, a failed installation keeps the files and can be retried, `opfs-busy` instead of a silent in-memory fallback (see Storage).

**Not met or not done:**

- **V2 by default.** The V3 transport, the negotiating transport and the session upgrade exist and are tested against the real server-side protocol code, but nothing has run against a live server, and the only key store is in memory. `RealtimeClient` takes an optional `v3` option; without it the client uses V2.
- **Identity on connect.** The client can send its type, version, device and time zone, but the server reads only some of those fields from `ConnectionInit`; the rest needs the `updateSession` RPC after the connection opens.
- **Coverage of the protocol.** About 32 of about 170 RPC methods are wrapped. Seventeen update kinds that used to be stored raw now have models (space members, chat participants and groups, user groups, folders, per-dialog notification and translation state, unread activity, user settings, space settings; replica schema version 4). The six agent update kinds and `acknowledgement` are still stored raw. Members, participants, user groups, folders and settings are exposed as queries (`chatParticipants`, `spaceMembers`, `userGroups`, `dialogFolders`, `userSettings`).
- **Edits, deletes, reactions, bot buttons and form submits** have no server idempotency key. The host refuses them offline (`offline`), sends them once, and reports one that was in flight when the connection dropped as `uncertain`. For these, `accepted` means admitted and shown in this session, not committed to disk; an open edit is lost if the core stops. This is the one documented exception to "a row in a patch is on disk": the displayed text of an open edit comes from an in-memory overlay on a confirmed base.
- **Intent results across a core restart** are followed for `sendText` (client key and `sendTx` record), `sendMedia` (its record) and the participant intents (their records' `tx`). Other durable intents re-posted to a later core run again (they are replay-safe, so the result is right but costs a second request); edits, deletes and reactions re-posted run again too.
- **`chatMedia` on a long chat** reads disk by decoding rows (the replica has no media column): a rare filter lists only what the newest 2,000 rows hold until `ensure older` or the server page answers. A `media_kind` column with an index `(chat_id, media_kind, message_id)` would make it an index range read; that is a replica schema change.
- **Disk eviction and retention are not built.** When they are, evicting a range must also remove it from coverage.
- **Notifications cannot honor the server's `countsAsUnread`**, because the replica does not store it.
- **One window per chat** is shared by every subscription to that chat, and trimming acts on that shared window.
- **Browser coverage.** Storage, the worker host and multi-tab handoff have been exercised by hand in Chromium only (`web/lab-storage.html`, `web/lab-core.html`). Nothing has run in Safari or Firefox, and there are no automated browser tests yet.
- **Version skew** between a UI and a core of different builds is transient (`link` makes the newest build lead and older contexts reload), but each addition degrades quietly: an older core refuses the new intents (participants, settings, media) with `unsupported`, keeps the new queries (`chatMedia`, `searchServerMessages`, `searchUsers`) empty, and ignores `draftRevision` (the draft stays after the send) and `attachFile.preview`; an older UI ignores `MessageRow.tx`, `ChatRow.dialogId`, `PhotoInfo.preview`, `CoreResource.signingOut` and `erased` (it closes on `signedOut` as before). An older core opening a replica that a newer one migrated stops on the outdated phase (invariant 9). Tested in `host/__tests__/version-skew.test.ts`.
- **Clocks.** `ConnectionManager` and `SyncEngine` use global timers; tests drive them with fake timers rather than an injected clock.
