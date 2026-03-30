# Chat Open Performance + Pagination + Go-To-Message Reliability (2026-02-07)

From notes (Feb 3-7, 2026): "speed up chat open", "fix message scroll load more", "reliable go to message", "load remotely".

Related docs already in repo:
- `/.agent-docs/chat-perf-plan.md`
- `/.agent-docs/chat-media-pagination-plan.md` (adjacent: server-side pagination patterns)

## Goals

- Initial chat open should render quickly (no obvious UI stall).
- Load-more should be correct (no gaps/dupes) and not thrash CPU.
- Go-to-message (reply/pin navigation) should work even if the target is not cached locally.
- Implement in a shared way so iOS + macOS converge on the same pagination semantics.

## Non-Goals (For Tomorrow)

- Full message view refactor; we only touch it if required for correctness/perf.
- Redesigning the UI; focus on data/pagination correctness and latency.

## High-Confidence Problems (From Code Review)

1. Main-thread DB work on chat open.
- `MessagesProgressiveViewModel` loads the initial batch synchronously on UI thread, causing open lag.
- File: `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift`

2. Pagination cursor uses `Date`, not `messageId`.
- Cursor logic uses `date <= cursor` while sorting `date desc, messageId desc`.
- Messages with identical timestamps can skip/duplicate.
- File: `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift`

3. Load-more is local-DB only.
- When cache is incomplete, load-more cannot continue because it never calls `getChatHistory` to backfill older messages.

4. iOS load-more thrashes (no in-flight guard).
- `scrollViewDidScroll` can trigger repeated loads while near the top.
- File: `apple/InlineIOS/Features/Chat/MessagesCollectionView.swift`

5. Go-to-message fails if message not loaded.
- macOS: retries only once and only loads locally (`apple/InlineMac/Views/MessageList/MessageListAppKit.swift`).
- iOS: reply scroll only works if message is in memory (`apple/InlineIOS/Features/Chat/MessagesCollectionView.swift`).

6. Server already supports offset-based history paging.
- `getChatHistory` uses `offsetId` (messageId), which matches the correct cursor model.
- Key files: `server/src/functions/messages.getChatHistory.ts`, `apple/InlineKit/Sources/InlineKit/Transactions2/GetChatHistoryTransaction.swift`.

7. Server has an internal "messages around target" query but no RPC.
- DB helper exists: `server/src/db/models/messages.ts` (`getMessagesAroundTarget`).

## Proposed Approach (Incremental, High Impact)

### Phase 1 (Tomorrow): Fix correctness + unblock remote backfill

1. Switch client pagination cursors to `messageId`.
- Track `oldestLoadedMessageId` and `newestLoadedMessageId`.
- Local DB pagination: load older messages using `messageId < oldestLoadedMessageId`.
- This removes timestamp-based gaps/dupes.

2. Add network backfill when local cache is exhausted.
- When local load returns fewer than `limit`, request `getChatHistory(offsetId: oldestLoadedMessageId)` and insert into DB.
- Continue local load once DB is filled.

3. Add in-flight + throttling guards (iOS and shared VM).
- One load at a time per direction.
- iOS should not call load on every scroll tick; throttle to scroll end or use cooldown.

### Phase 2 (Tomorrow or next): Make go-to-message reliable

Option A (recommended): Add a new RPC "getMessagesAround" for a target messageId.
Server: implement `messages.getMessagesAround(chatId, messageId, before, after)` using existing model helper; encode as full messages and return a window. Client: if target not found, call getMessagesAround, insert into DB, then scroll.

Option B: Iteratively page older via `getChatHistory` until found.
- Pros: no new RPC.
- Cons: slow for far targets; risk of many requests.

### Phase 3: Reduce initial open cost further

- Move initial load off main actor.
- Consider a "light" message query for initial list, with lazy hydration for heavy relations.

## Server Changes (If Implementing Option A)

1. Proto
- Add `GetMessagesAroundInput { chat_id, message_id, before_count, after_count }`
- Add `GetMessagesAroundResult { repeated FullMessage messages }`

2. Server function + handler
- New function: `server/src/functions/messages.getMessagesAround.ts`
- New handler: `server/src/realtime/handlers/messages.getMessagesAround.ts`
- Use `MessageModel.getMessagesAroundTarget(...)` and `Encoders.fullMessage(...)`.

3. Tests
- Add server test: returns window with correct ordering and bounds.

## Apple Client Changes

InlineKit:
- Refactor `MessagesProgressiveViewModel` to use messageId cursor + async initial load.
Touchpoint: `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift`.
- Add a transaction wrapper for getMessagesAround (if added).

iOS:
- Add load-more guard and reduce repeated calls.
Touchpoint: `apple/InlineIOS/Features/Chat/MessagesCollectionView.swift`.
- Update reply/pin scroll to fetch around target if not found.

macOS:
- Update go-to-message to call around-target fetch if missing and then highlight reliably.
Touchpoint: `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`.

## Acceptance Criteria

1. Chat open: no obvious stall on large chats (subjective + Instruments).
2. Load-more: no duplicates/gaps when scrolling older; cursor strictly monotonic by messageId.
3. Go-to-message: replies/pins navigate successfully even for older, uncached messages.

## Test Plan

Manual:
1. Large chat open on iOS + macOS.
2. Scroll older until local cache ends; verify remote backfill continues smoothly.
3. Tap reply to a very old message; confirm it loads and scrolls to it.

Automated:
- InlineKit tests for pagination invariants (cursor monotonic, no dupes).
- Server tests for getMessagesAround and/or getChatHistory paging.

## Risks / Tradeoffs

- Introducing remote backfill can increase request volume; needs simple caching/in-flight guards.
- Inserting around-target windows must be idempotent (safe upserts) to avoid duplicates and side effects.
