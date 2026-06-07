# Client Updating, Realtime, Catch-up, and DB Performance Investigation

Date: 2026-06-06
Status: Investigation complete, implementation not started
Owner/reviewer: Mo

## Executive Summary

The visible "updating" state is not primarily a transport connection block. In RealtimeV2, the transport can already be connected while sync activity keeps the UI state in `.updating`. Transactions are still allowed in `.updating`, so the user-visible lag is likely caused by catch-up scheduling, local DB apply, message-list reloads, and server-side bucket discovery/inflation work.

The recent timing lines up with several changes from the past few weeks:

- 2026-05-11: stable message sync became default-on.
- 2026-05-25: `getUpdatesState` started filtering changed update buckets through access guards.
- 2026-05-27: client update page limit became 200.
- 2026-06-01: URL previews started syncing and rendering, increasing message payload/apply/render cost.

There are two distinct tracks:

1. Reliability failures that can trap a sync cursor or repeatedly schedule catch-up. The staged sync reliability patch addresses important pieces here, especially sidecars and invalid bucket handling.
2. Latency and UI responsiveness problems where catch-up succeeds but is visibly slow or causes hangs due to server query work, payload inflation, local SQLite writes, and full message-list reloads.

This report focuses on the second track while calling out how the first track interacts with it.

## Current Worktree Context

The repo currently has a dirty worktree and a staged sync reliability patch. This investigation did not modify code.

Staged sync patch areas:

- `proto/core.proto`
- `packages/protocol/src/core.ts`
- `server/src/functions/updates.getUpdates.ts`
- `server/src/modules/updates/sync.ts`
- `apple/InlineKit/Sources/InlineProtocol/core.pb.swift`
- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift`
- `apple/InlineKit/Sources/RealtimeV2/Sync/SyncApplyUpdate.swift`
- `apple/InlineKit/Sources/InlineKit/ApplyUpdates.swift`
- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift`
- `apple/InlineKit/Sources/InlineKit/Models/Message.swift`
- sync/replay tests

Important staged patch summary from prior work:

- Adds `UpdateSidecars`.
- Sends catch-up sidecars.
- Keeps delivered updates contiguous.
- Adds stricter realtime/materialize behavior for catch-up references.
- Invalidates invalid peer buckets.
- Improves cursor correctness and `chatSkipPts` handling.
- Adds regression tests.

Production behavior must be evaluated against `HEAD`, not the staged tree, where these fixes are not yet deployed.

## End-to-end Flow

### 1. Connection Open

`RealtimeV2` starts session and connection manager listeners. On protocol open, the connection manager publishes `.open`, which maps to `RealtimeConnectionState.connected`.

Relevant code:

- `apple/InlineKit/Sources/RealtimeV2/Realtime/Realtime.swift`
- `apple/InlineKit/Sources/RealtimeV2/Connection/ConnectionManager.swift`

When the transport state becomes connected, RealtimeV2 notifies sync:

```swift
Task { await sync.connectionStateChanged(state: newState) }
await publishConnectionStateIfNeeded()
```

Reference:

- `apple/InlineKit/Sources/RealtimeV2/Realtime/Realtime.swift:500`

### 2. Sync Starts Catch-up

On `.connected`, sync always fetches the user bucket and calls `getUpdatesState`:

```swift
case .connected:
  fetchUserBucket()
  getStateFromServer()
```

Reference:

- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:196`

`getUpdatesState` sends the client's last sync date to the server. The server finds changed chats/spaces since that date, then pushes `chatHasNewUpdates` and `spaceHasNewUpdates` hints back to the same user.

References:

- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:317`
- `server/src/functions/updates.getUpdatesState.ts:16`
- `server/src/functions/updates.getUpdatesState.ts:69`

### 3. Bucket Hint Fanout

For each `chatHasNewUpdates` or `spaceHasNewUpdates`, the client creates or reuses a `BucketActor` and calls `noteHasNewUpdatesAndMaybeFetch`.

References:

- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:275`
- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:283`

Each bucket actor fetches its own difference via `getUpdates`.

Reference:

- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:842`

### 4. Activity Accounting Drives UI Updating

RealtimeV2 publishes `.updating` when:

```swift
transportConnectionState == .connected && syncActivityInProgress
```

Reference:

- `apple/InlineKit/Sources/RealtimeV2/Realtime/Realtime.swift:513`

Transactions are still allowed while `.updating`:

```swift
case .connected, .updating:
  true
```

Reference:

- `apple/InlineKit/Sources/RealtimeV2/Realtime/Realtime.swift:528`

The important performance issue: bucket fetch activity starts before the bucket has passed the global fetch limiter.

Activity starts:

- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:865`

Limiter acquisition happens later:

- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:944`

That means queued bucket work can keep the UI in "updating" even before it is actively using network or applying updates.

### 5. Server getUpdates

The client currently requests up to 200 updates per bucket page:

- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:624`

Server `getUpdates`:

1. Resolves the bucket and checks access.
2. Fetches update rows from `updates`.
3. Inflates chat updates by decrypting payloads and loading referenced messages/attachments.
4. Returns a slice or `TOO_LONG`.

References:

- `server/src/functions/updates.getUpdates.ts:36`
- `server/src/modules/updates/sync.ts:54`
- `server/src/modules/updates/sync.ts:125`

The staged patch also adds sidecars and contiguous delivered-prefix semantics:

- `server/src/functions/updates.getUpdates.ts:125`
- `server/src/modules/updates/sync.ts:528`

### 6. Client Apply

Catch-up updates are applied through `UpdatesEngine.applyBatch`. It chunks catch-up writes at 200 updates:

- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift:170`

Within each chunk, updates are applied in a single writer transaction. After all chunks, catch-up reloads all touched peers on MainActor:

- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift:225`

### 7. Message-list Reload

For the active peer, `MessagesPublisher.messagesReload` enters `MessagesProgressiveViewModel.applyChanges`.

If the user is at bottom, it reloads latest messages:

- `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift:306`

If not at bottom, it refetches the current date range:

- `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift:314`

Reload uses `FullMessage.queryRequest`, which loads a rich graph:

- sender user and profile photos
- forward user/chat info
- reply thread
- file
- reactions and reaction users/photos
- replied-to message and its media/translations
- attachments and URL previews
- photo/video/document info and sizes
- translations

Reference:

- `apple/InlineKit/Sources/InlineKit/ViewModels/FullChat.swift:210`

### 8. Platform UI Reload

iOS rebuilds a diffable snapshot for the whole visible window and reconfigures all existing item identifiers:

- `apple/InlineIOS/Features/Chat/MessagesCollectionView.swift:792`

macOS often falls back to `NSTableView.reloadData()`, which can force cell rebuilds and row-height recalculation:

- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift:1275`
- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift:1401`

## Findings

### Finding 1: `.updating` Can Reflect Queue Depth, Not Active Work

`activeBucketFetches` increments before `fetchLimiter.acquire()`. With many changed buckets after reconnect, the UI can show "updating" while many bucket actors are simply waiting for the limiter.

Impact:

- Users see multi-second updating even if the transport is open.
- It hides whether the app is doing useful network/apply work or just waiting on internal queueing.
- It can overstate catch-up duration.

Risk of changing:

- Low if we keep cursor/apply semantics unchanged and only split queued vs active counters.
- Medium if we hide all catch-up indicators, because users and debugging lose visibility into real sync work.

Recommended direction:

- Track queued, active RPC, and active apply separately.
- Drive UI `.updating` from active RPC/apply work or a short bounded catch-up grace window.
- Keep debug stats showing queued bucket count.

### Finding 2: `getUpdatesState` Fans Out into Many Bucket RPCs

The server `getUpdatesState` scans changed chats/spaces since a global date, pushes one hint per changed bucket, and returns a date.

Impact:

- A reconnect can produce many bucket actors and many `getUpdates` RPCs.
- Client sees queue depth.
- Server and client do duplicated access work: discovery checks access, then each bucket RPC resolves/access-checks again.

Recommended direction:

- First pass: instrument bucket counts and durations.
- Low-risk server improvement: add indexes on `last_update_date` for chats and spaces.
- Later: consider changing `getUpdatesState` to return compact bucket hints directly instead of pushing side effects.
- Later: consider batching bucket fetches or returning per-bucket latest seqs in a single response.

### Finding 3: Server Discovery Has Likely Missing Indexes

`getUpdatesState` filters by `lastUpdateDate` for chats/spaces, but schema does not define dedicated indexes for those fields.

References:

- `server/src/db/schema/chats.ts:60`
- `server/src/db/schema/spaces.ts:20`

Impact:

- Reconnect discovery can be expensive for users with many chats/spaces.
- This cost happens before bucket catch-up starts.

Recommended direction:

- Add `chats(last_update_date)` and `spaces(last_update_date)` indexes.
- Depending on EXPLAIN and data shape, consider composite indexes that match membership/access query patterns.

### Finding 4: Access Filtering is Sequential in `getUpdatesState`

`filterAccessibleChats` loops through every changed chat and calls `AccessGuards.ensureChatAccess`.

Reference:

- `server/src/functions/updates.getUpdatesState.ts:120`

Access guards can hit:

- direct chat participant lookup
- parent chat lookup for subthreads
- space member lookup
- member access flags for public threads

Reference:

- `server/src/modules/authorization/accessGuards.ts:17`

Impact:

- Sequential per-chat access filtering can add latency proportional to changed bucket count.
- Some cache helps, but cold reconnect/user-specific state still pays.

Recommended direction:

- First pass: instrument how many chats are scanned, how many require DB access, and total filter duration.
- Later: replace per-chat checks with query-time filtering or batch membership/participant maps.

### Finding 5: `limit = 200` Increases Per-RPC Payload and Apply Cost

May 27 allowed client page limits and the client currently uses 200.

Reference:

- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:624`
- `server/src/functions/updates.getUpdates.ts:66`

Impact:

- Fewer round trips, but larger payloads.
- More server message inflation per RPC.
- More local DB work per catch-up batch.
- More likely to create a noticeable main-thread reload after apply.

Recommended direction:

- Instrument p50/p95 latency and payload size for page sizes.
- Consider dynamic page size:
  - active/open chat: smaller page and progressive publish
  - background/inactive buckets: larger page
  - media/attachment-heavy buckets: smaller page

### Finding 6: Chat Update Inflation is Heavy

For chat updates, server processing does more than read update rows:

- decrypt update payloads
- collect message IDs
- fetch full messages with media/reactions/voice/file relations
- fetch attachments in a separate batch
- decrypt message text/entities/actions
- compute reply summaries
- encode full protocol messages
- in staged patch, build sidecars

References:

- `server/src/modules/updates/sync.ts:125`
- `server/src/db/models/messages.ts:245`
- `server/src/db/models/messages.ts:267`
- `server/src/db/models/messages.ts:307`
- `server/src/db/models/messages.ts:461`

Impact:

- A "200 updates" page can be a large CPU/DB/decryption operation.
- URL preview attachments and media make this worse.

Recommended direction:

- Instrument by update type and by counts of messages, attachments, sidecars.
- Later: avoid fetching full message graphs for update types that do not need them.
- Later: introduce lighter catch-up payloads for inactive chats.

### Finding 7: Client Apply Has Per-message DB Work

Saving a message can do:

- existing message lookup
- link detection
- pinned state lookup
- media save/update
- reactions save
- attachments save
- `Chat.updateLastMsgId`
- unread/dialog updates
- sidecar materialization in staged patch

References:

- `apple/InlineKit/Sources/InlineKit/Models/Message.swift:910`
- `apple/InlineKit/Sources/InlineKit/Models/Message.swift:925`
- `apple/InlineKit/Sources/InlineKit/Models/Message.swift:953`
- `apple/InlineKit/Sources/InlineKit/Models/Message.swift:974`
- `apple/InlineKit/Sources/InlineKit/Models/Chat.swift:368`

Impact:

- Large pages are not simple inserts.
- Per-message `Chat.updateLastMsgId` is likely more expensive than batching once per chat.
- Link detection uses `NSDataDetector` if server/client did not set `hasLink`.

Recommended direction:

- First pass: timing around message save and apply chunk duration.
- Later: batch `Chat.updateLastMsgIds` in catch-up.
- Later: avoid fallback link detection when server reliably sends `hasLink`.
- Later: batch pinned lookup or avoid per-message pin checks where `pinnedMessages` update is authoritative.

### Finding 8: Catch-up Publishes Full Reloads for Touched Peers

Catch-up suppresses per-update publish side effects, collects touched peers, then emits one reload per peer.

Reference:

- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift:225`

Impact:

- Better than publishing every message, but still costly for active chat.
- Multiple bucket/chunk cycles can still cause repeated reloads.
- Inactive chat reloads are skipped on iOS because `MessagesPublisher.shouldPublish` gates active chats, but macOS currently publishes for all peers.

Recommended direction:

- First pass: debounce/coalesce catch-up reloads per peer.
- Later: only publish active peers on macOS too, or distinguish background model updates from active message-list updates.
- Later: publish incremental changes for active chat when safe.

### Finding 9: Active Chat Reload Reads Are MainActor-bound

`MessagesProgressiveViewModel` is MainActor-owned and `loadMessages` performs synchronous reads:

- `fetchMessages`
- `updateLoadedWindowMetadata`

References:

- `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift:677`
- `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift:777`
- `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift:507`

There are async helpers for some additional load paths, but reload currently uses sync reads.

Impact:

- On reconnect, DB reads and rich row decoding can run from the MainActor path.
- Even with `DatabasePool`, this can block UI update processing.

Recommended direction:

- First pass: move reload fetches to async background reader, then assign results on MainActor.
- Keep query shape unchanged in the first pass to reduce correctness risk.

### Finding 10: UI Reload Paths Are Expensive

iOS:

- `setInitialData` rebuilds a snapshot for every section/item.
- It reconfigures every existing item that remains in the snapshot.

Reference:

- `apple/InlineIOS/Features/Chat/MessagesCollectionView.swift:792`

macOS:

- `reloadData` can force cell rebuilding and row height recalculation.
- Existing signposts exist for layout, height recalculation, cell creation, and row height, but sync/apply/reload is not tied together end to end.

Reference:

- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift:1275`
- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift:1560`

Impact:

- Catch-up can cause visible hangs even after DB apply completes.
- URL preview/media rows make row height and cell build costs larger.

Recommended direction:

- First pass: instrument reload/snapshot/apply durations.
- Later: avoid full snapshot reconfigure on reload when only a subset changed.
- Later: apply incremental row reloads/inserts for catch-up when message IDs are known.

## Proposed First Batch for Approval

Goal: one low-risk unit that improves observability and removes obvious over-reporting/reload storms without changing sync correctness or cursor semantics.

### Batch 1.1: Sync Timing and Counters

Add lightweight logs or signposts for:

- connection open to `getUpdatesState` request and response
- changed bucket count from server
- bucket fetch queued
- bucket limiter acquired
- getUpdates RPC duration
- response update count, sidecar count, result type
- apply duration
- reload publish duration
- sync activity state transitions

Client locations:

- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift`
- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift`
- `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift`
- `apple/InlineIOS/Features/Chat/MessagesCollectionView.swift`
- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`

Server locations:

- `server/src/functions/updates.getUpdatesState.ts`
- `server/src/functions/updates.getUpdates.ts`
- `server/src/modules/updates/sync.ts`

Why low risk:

- No protocol changes.
- No DB schema changes unless we include indexes separately.
- Helps verify the rest.

Test/validation:

- Unit tests not needed for pure timing logs unless counters alter behavior.
- Manual/profiling validation: reconnect with dirty buckets and compare durations.

### Batch 1.2: Separate Queued vs Active Bucket Work

Change activity accounting so queued buckets do not keep `.updating` active before they acquire the limiter.

Proposed semantics:

- `queuedBucketFetches`: debug stat only.
- `activeBucketFetches`: increments after limiter acquisition, decrements after RPC/apply path completes.
- `syncActivityInProgress`: true when active RPC/apply is ongoing.
- Optional short grace, for example 150-300ms, to avoid flicker between pages.

Why low risk:

- Does not change what is fetched.
- Does not change cursor advancement.
- Does not change apply order.
- Only changes UI-facing activity signal and stats.

Risk:

- Could hide real queued catch-up. Mitigate with debug stats and logs.

Tests:

- A fake limiter test where several bucket fetches queue and only acquired fetches mark activity active.
- Existing `SyncTests`.

### Batch 1.3: Coalesce Catch-up Reloads

Add a coalescing path for catch-up reloads so the same peer is reloaded at most once per short debounce window.

Proposed behavior:

- `UpdatesEngine.applyBatch` still returns touched peers.
- `MessagesPublisher` gets a catch-up reload API or reload source metadata.
- Catch-up reloads are collected per peer for a short debounce window.
- Active peer receives one reload after the batch burst settles.

Why low risk:

- Does not skip DB writes.
- Does not alter sync cursor.
- Existing UI already handles full reload.
- Coalescing only reduces duplicate reloads.

Risk:

- UI may reflect catch-up changes a few milliseconds later.
- Need care with deletes/clear-history where immediate UI removal may matter.

Tests:

- Multiple catch-up reload calls for same peer produce one publisher event.
- Realtime direct message updates still publish immediately.
- Clear/delete reload still eventually publishes.

### Batch 1.4: Server Reconnect Discovery Indexes

Add Drizzle-generated indexes:

- `chats(last_update_date)`
- `spaces(last_update_date)`

Why low risk:

- Pure schema performance improvement.
- No behavior change.

Risk:

- Migration time on large tables. Need review generated SQL and consider concurrent index creation if the migration system supports it.

Tests:

- Generate migration with Drizzle flow.
- Server typecheck.
- Confirm generated SQL names and no accidental schema churn.

### Batch 1.5: Move Active Chat Reload Reads off Synchronous MainActor Path

For catch-up reloads, use async reader paths for message reload and loaded-window metadata where possible. Keep `FullMessage.queryRequest` unchanged in this first batch.

Why low risk:

- Same data, same query shape.
- Avoids blocking MainActor on rich message row decoding.

Risk:

- Need cancellation handling so stale reload results do not apply after peer changes.
- Need preserve ordering with manual loads and scroll state.

Tests:

- Existing `FullChatProgressiveTests`.
- Add targeted test if the model has test hooks for reload ordering/cancellation.

## Proposed First Batch Acceptance Criteria

1. Reconnecting with many changed buckets should not show `.updating` solely because bucket work is queued behind the limiter.
2. One catch-up burst for one active peer should trigger at most one visible reload after coalescing.
3. Server reconnect discovery should have indexes supporting `last_update_date` filtering.
4. Logs/signposts should show enough timing to separate:
   - server state discovery
   - server update inflation
   - client RPC wait
   - client DB apply
   - client UI reload
5. No cursor advancement changes.
6. Existing sync reliability tests still pass.

## Backlog After First Batch

### Batch 2: Server Access Filtering and Bucket Hint Return Shape

Ideas:

- Replace sequential `filterAccessibleChats` with query-time filtering.
- Batch membership/participant checks.
- Return compact bucket hints from `getUpdatesState` instead of pushing side-effect updates.
- Include latest seq/date per bucket directly in the response.

Why:

- Reduces reconnect fanout and nondeterminism.
- Makes state discovery easier to test and measure.

Risk:

- Protocol/API behavior change.
- Must preserve old client compatibility or stage rollout.

### Batch 3: Dynamic getUpdates Page Size

Ideas:

- Smaller pages for active chat and media-heavy buckets.
- Larger pages for inactive buckets.
- Bound payload bytes, not just update count.
- Server can return a hint when payload is large.

Why:

- Avoids 200 full-message payloads causing a single latency spike.

Risk:

- More RPC round trips if page size is too small.
- Need metrics before tuning.

### Batch 4: Lighter Catch-up Message Projection

Ideas:

- Separate message-list row projection from full message detail.
- Avoid loading all media/attachment/reaction/translation graphs for initial reload unless visible cells need them.
- Lazy-load URL preview details for visible messages.

Why:

- `FullMessage.queryRequest` is rich and expensive for reload.

Risk:

- High. This touches UI data contracts.
- Needs focused tests and screenshots.

### Batch 5: Incremental Catch-up UI Updates

Ideas:

- For active peer, publish added/updated/deleted message IDs from catch-up instead of full reload.
- Only full reload when order/range/structure cannot be resolved safely.
- Avoid iOS snapshot reconfigure-all on reload.
- Avoid macOS `reloadData` when row-level updates are enough.

Why:

- Biggest UI responsiveness win after observability and coalescing.

Risk:

- Medium/high. Must preserve message order, same-second ordering, scroll anchoring, unread markers, and section boundaries.

### Batch 6: Batch Local DB Side Effects

Ideas:

- Batch `Chat.updateLastMsgIds` per catch-up chunk.
- Avoid per-message pinned lookup when not needed.
- Use server-provided `hasLink` as authoritative where possible.
- Batch sidecar reference materialization checks.

Why:

- Reduces write transaction duration and per-message query count.

Risk:

- Medium. Last-message correctness and pinned state are user-visible.

### Batch 7: Better Sync State Model

Ideas:

- Separate "connecting", "connected but catching up", "queued catch-up", and "active catch-up".
- UI can show only meaningful states.
- Debug settings can show detailed queued/active bucket counters.

Why:

- Prevents "updating" from becoming a vague catch-all.

Risk:

- Low/medium. UI and user expectations change.

## Test Plan for Sync Performance Work

Focused tests:

- `SyncTests`: bucket fetch activity, retry behavior, queued vs active fetches.
- `RealtimeSendTests`: ensure transactions still execute while `.updating`.
- `UnreadReplayGuardTests`: ensure catch-up replay does not regress unread state.
- `updates.getUpdates.test.ts`: contiguous delivery, sidecars, `TOO_LONG`, skipped update behavior.
- New publisher coalescing tests around `MessagesPublisher`.
- New migration/schema test or generated SQL review for indexes.

Manual/perf validation:

- Reconnect with many dirty buckets.
- Reconnect with active chat containing URL preview/media updates.
- Reconnect while not at bottom.
- Reconnect with open thread chat.
- Compare:
  - time to `.connected`
  - visible `.updating` duration
  - `getUpdatesState` duration
  - bucket queue wait duration
  - getUpdates p50/p95 duration
  - DB apply duration
  - message reload duration
  - iOS snapshot apply duration
  - macOS reloadData/row height duration

## Production Readiness Notes

The staged reliability patch should be considered separately from performance work. It likely addresses stuck-updating loops caused by missing references and invalid bucket retries. However, it does not by itself make catch-up cheap.

Recommended order:

1. Finish/review/ship the staged reliability patch if it is already approved and checks pass.
2. Implement Batch 1 above with review before and after implementation.
3. Use added timings to decide whether Batch 2, 3, 5, or 6 should be next.

Security risk in Batch 1:

- Low. No sensitive data should be logged. Timing logs must avoid message text, peer names, tokens, URLs, or decrypted content.

Performance risk in Batch 1:

- Low if logging is bounded and disabled or concise in production.
- Index migration needs deployment review.

Correctness risk in Batch 1:

- Low for instrumentation and indexes.
- Low/medium for activity accounting because it changes visible state semantics.
- Low/medium for reload coalescing because delayed UI updates can expose ordering/cancellation bugs.

## Approval Gate

No implementation should start until Mo reviews and approves the first batch spec.

After implementation, Mo should review:

- staged diff
- tests added/changed
- timing log fields
- migration SQL
- final behavior notes from local validation
