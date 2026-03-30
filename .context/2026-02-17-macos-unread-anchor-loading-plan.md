# macOS Unread Anchor Loading Plan (2026-02-17)

## Requested Outcome

When opening a chat on macOS:

1. Start from the first unread message (not always bottom).
2. Show a separator above that first unread message (Telegram-style).
3. Load a window centered on unread (some older + newer context).
4. Anchor initial scroll to that unread point.
5. Show loading spinner instead of stale cached messages when unread anchor data is missing.
6. Support bidirectional cache pagination (older + newer), not only older.

## Current Architecture (Verified)

### Chat open + fetch orchestration

- `apple/InlineMac/Views/ChatView/ChatViewAppKit.swift` mounts `MessageListAppKit` as soon as chat exists in local DB (`state = .loaded`), even while fresh history fetch is in progress.
- `apple/InlineKit/Sources/InlineKit/ViewModels/FullChat.swift` (`FullChatViewModel`) triggers:
  - `.getChat(peer:)`
  - `.getChatHistory(peer:)`
  - optional user fetch
- This path currently fetches the latest history chunk, not an unread-centered window.

### Message list + table behavior

- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift` uses `NSTableView` with `RowItem` containing day separators + message rows.
- Initial layout path scrolls to bottom (`needsInitialScroll` flow), then marks read.
- Existing unread UI is only a dot on scroll-to-bottom button; no in-list unread separator row.

### Progressive view model + local pagination

- `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift` (`MessagesProgressiveViewModel`) loads initial messages from local DB and tracks date cursors.
- `MessageListAppKit` currently calls load-more only for `.older`.
- No explicit `.newer` pagination path from table scroll.

### Unread metadata source

- `Dialog.readInboxMaxId`, `Dialog.unreadCount`, `Dialog.unreadMark` in:
  - `apple/InlineKit/Sources/InlineKit/Models/Dialog.swift`
  - schema in `apple/InlineKit/Sources/InlineKit/Database.swift`
- First unread can be derived as first message with `messageId > readInboxMaxId` for current chat.

### API contract limitation

- `getChatHistory` supports `offsetId` paging backwards (`messageId < offsetId`) and `limit`.
- It does not expose true around-anchor window loading by messageId.
- Server already has `MessageModel.getMessagesAroundTarget(...)` but not exposed to Apple chat-open path.

## Telegram Reference Patterns (for robustness)

### Telegram iOS (Telegram-iOS/Postbox)

- Initial open uses an "around message of interest" strategy keyed by read state, then falls back to latest.
- History view tracks holes explicitly (`holeEarlier`, `holeLater`, hole direction).
- Remote fetch is hole-driven and deduplicated with in-flight suppression.
- Relevant local files:
  - `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/AccountViewTracker.swift`
  - `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/Postbox.swift`
  - `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/MessageHistoryView.swift`
  - `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/ManagedMessageHistoryHoles.swift`
  - `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/Holes.swift`

### Telegram Desktop + TelegramSwift (macOS)

- Initial load chooses anchor (latest, unread, explicit target), not one fixed bottom-only mode.
- Scroll model knows if top/bottom is fully loaded and only fetches remote at boundaries.
- Gap/hole states are first-class and UI can stay in loading mode until hole fill completes.
- Relevant local files:
  - `/Users/mo/dev/telegram/tdesktop/Telegram/SourceFiles/history/history_widget.cpp`
  - `/Users/mo/dev/telegram/tdesktop/Telegram/SourceFiles/history/history_inner_widget.cpp`
  - `/Users/mo/dev/telegram/tdesktop/Telegram/SourceFiles/history/history.cpp`
  - `/Users/mo/dev/telegram/TelegramSwift/Telegram-Mac/ChatHistoryViewForLocation.swift`

### Telegram Web (k + z)

- Chat open computes unread/focused anchor and loads around it.
- Both directions can load from edges with explicit throttling/in-flight guards.
- Gaps are merged into tracked outlying ranges and normalized back into the main list.
- Relevant local files:
  - `/Users/mo/dev/telegram/Telegram-web-k/src/components/chat/bubbles.ts`
  - `/Users/mo/dev/telegram/Telegram-web-k/src/lib/appManagers/appMessagesManager.ts`
  - `/Users/mo/dev/telegram/Telegram-web-z/src/components/middle/MessageList.tsx`
  - `/Users/mo/dev/telegram/Telegram-web-z/src/components/middle/hooks/useScrollHooks.ts`
  - `/Users/mo/dev/telegram/Telegram-web-z/src/global/actions/api/messages.ts`
  - `/Users/mo/dev/telegram/Telegram-web-z/src/global/reducers/messages.ts`

## Updated Technical Direction

Model this as one coherent "history window + gap model" project, shipped in phased slices.

Core idea:

1. Keep a window of messages in view model (`oldestLoadedMessageId...newestLoadedMessageId`).
2. Track whether older/newer sides are fully loaded locally and remotely.
3. Track missing ranges ("gaps") explicitly, not implicitly via failed scroll attempts.
4. Open chat around unread anchor when available, otherwise around latest.
5. Allow pagination in both directions from this anchor window.

This mirrors Telegram's proven pattern and gives compatibility with upcoming proper sync.

## Should We Do Remote Load-More in This Task?

Yes, but in the same architecture, not as a separate future refactor.

Reason:

1. Unread-anchored open without remote load-more creates dead ends for clear-cache users.
2. Gap recovery requires the same primitives as remote load-more (range tracking + fill).
3. Proper sync rollout will need these primitives anyway.

Recommended delivery split:

1. Foundation slice: gap/range model + bidirectional remote/local loaders + anchor bootstrapping APIs.
2. UX slice: unread separator, initial anchor scroll behavior, spinner gating.
3. Hardening slice: gap recovery policies, sync integration, telemetry/tests.

## Execution Plan (Robust)

### Phase 0: Surgical prep refactors (recommended)

1. Extract `MessagesProgressiveViewModel` responsibilities into clearer units without behavior change:
   - query builder / cursor math
   - merge + dedupe
   - change-set publishing
2. Add narrow unit tests around current behavior before functional changes.
3. Keep API surface compatible so iOS/other call sites continue unchanged.

### Phase 1: Data model for window + gaps (InlineKit)

1. Extend `MessagesProgressiveViewModel` with messageId-based window state:
   - `oldestLoadedMessageId`
   - `newestLoadedMessageId`
   - `hasOlderLocal`
   - `hasNewerLocal`
   - `hasOlderRemote`
   - `hasNewerRemote`
2. Introduce gap tracking structure (per chat):
   - sorted missing ranges by messageId
   - merge-on-insert behavior
   - in-flight flags per range or per direction
3. Keep default constructor behavior unchanged for iOS callers; new capabilities must be opt-in for macOS first.

### Phase 2: Remote APIs for anchored windows + directional paging

1. Keep a single history RPC path using `GetChatHistoryInput`.
2. Add explicit mode field on `GetChatHistoryInput`:
   - `older(before_id, limit)`
   - `newer(after_id, limit)`
   - `around(anchor_id, before_limit, after_limit, include_anchor)`
   - optional `latest(limit)` mode
3. Keep legacy `offset_id` support as migration compatibility shim.
4. On server, reuse existing `MessageModel.getMessagesAroundTarget(...)` for around mode and directional queries for older/newer.

### Phase 2.1: RPC contract proposal (concrete)

Telegram pattern:

- Uses one flexible history RPC (`messages.getHistory`) with cursor params that support directional and around-target retrieval.
- Around-target is used for anchor/hole fill; ordinary load-more is mostly directional from edges.

Inline proposal (single endpoint in `GetChatHistoryInput`, explicit mode, backward-compatible):

1. Keep one RPC for history loading (existing `getChatHistory` path), no second RPC.
2. Add explicit query mode field to the same input:
   - `older(before_id, limit)`
   - `newer(after_id, limit)`
   - `around(anchor_id, before_limit, after_limit, include_anchor)`
   - optional `latest(limit)` convenience mode
3. Keep legacy `offset_id` behavior as compatibility shim during migration, then deprecate.

Important server note:

- Existing `MessageModel.getMessagesAroundTarget(...)` excludes the exact target row (`< target`, `> target` only).
- For unread anchoring, include target message in result (or fetch target separately and merge) so the anchor row always exists in the rendered window.

### Phase 2.2: Flexible RPC shape options (Telegram-like vs explicit)

Decision (Mo, 2026-02-18):

- Use explicit flexible mode.
- Keep it in one existing history RPC path by adding a mode field (not multiple RPCs).

### Phase 3: Unread anchor resolution + bootstrap

1. Resolve first unread anchor from `Dialog.readInboxMaxId` and chat message IDs.
2. Bootstrap policy:
   - anchor available and sufficiently cached -> local around-anchor window
   - anchor missing or partial -> remote around-target fetch
   - spinner only when: connected + authed + fetch in progress
   - when offline/disconnected: do not show blocking spinner; keep cached state
   - no unread -> latest-window bootstrap
3. Add explicit bootstrap state in chat open flow so stale cached bottom window is not shown while unresolved anchor load is pending.
4. Future compatibility rule (saved scroll position):
   - when saved scroll position feature ships, open-anchor priority becomes:
   - explicit target (search/reply/jump) -> saved position -> unread anchor -> latest

### Phase 3.1: Targeted jump navigation (pinned/reply/media-files go-to)

Goal:

- For jumps to older uncached messages, do not load all intermediate history.
- Load a window around target, then scroll/highlight target, then rely on normal bidirectional pagination.

Current macOS new UI entry points (verified):

1. Reply/embedded tap -> `EmbeddedMessageView.handleTap` -> `ChatState.scrollTo(msgId:)`
2. Forward-header tap -> `MessageView.handleForwardHeaderClick` -> `ChatState.scrollTo(msgId:)` (same peer or after opening other chat)
3. Pinned header tap (through embedded view in pinned header) -> `ChatState.scrollTo(msgId:)`
4. Future/adjacent surfaces (chat info files/media/links go-to-message) should call the same path.

Implementation:

1. Add a single jump request path in message list/view model:
   - input: `targetMessageId`, `reason` (reply, pinned, media, link, forwarded, search)
2. Local-first check:
   - if target exists in current window, scroll+highlight immediately
   - else if target exists in local DB but outside window, rebuild window around target from local cache
3. Remote fallback:
   - call `getChatHistory` with explicit `around(anchor_id, before, after, include_anchor=true)`
   - merge into DB/window, then scroll+highlight
4. Do not page from current position to target via repeated older batches.
5. After jump, pagination remains edge-driven (`older`/`newer`) as user scrolls.
6. Spinner policy for target jumps:
   - same as anchor policy: blocking spinner only when connected+authed and fetch is in-flight
   - offline/disconnected: no blocking spinner; keep available cached content

### Phase 4: Bidirectional load-more (local then remote)

1. Top-edge:
   - load older from local cache first
   - if exhausted and `hasOlderRemote`, fetch remote older batch and persist
2. Bottom-edge:
   - load newer from local cache first
   - if exhausted and `hasNewerRemote`, fetch remote newer batch and persist
3. Shared in-flight/cooldown guards per direction to prevent duplicate requests.
4. Preserve table anchoring for inserts on either side.

### Phase 5: Gap handling policy

1. Detect gap when:
   - remote history indicates discontinuity
   - expected message range missing around anchor
   - sync reports seq continuity but messageId span is missing
2. Fill strategy (default):
   - mark missing range
   - lazy fill when viewport approaches range or anchor depends on it
   - background fill small nearby gaps eagerly
3. Hard reset strategy (fallback only):
   - clear chat-local message cache and refetch baseline window
   - use only on repeated unrecoverable gap states (telemetry-backed), not as default path
4. De-dupe by messageId on every merge.

### Phase 6: Unread separator + initial scroll anchoring (AppKit)

1. Extend `RowItem` with unread separator row.
2. Insert separator above first unread row in current window.
3. Replace bottom-first initial scroll with anchor-first when unread bootstrap active.
4. Keep configurable placement offset (top-padded preferred for context readability).

### Phase 7: Read-state semantics

1. Do not auto-`readAll` during unresolved anchor bootstrap.
2. Mark read when user reaches bottom or explicit threshold condition.
3. Keep `UnreadManager` and sidebar unread badge logic consistent.

### Phase 8: Sync compatibility contract

Must remain compatible with experimental proper sync path:

1. Do not bypass update application pipeline (`ApplyUpdates` / DB observers).
2. Keep unread-anchor logic derived from DB state (`Dialog.readInboxMaxId` + messages), not transient network state.
3. Make gap tracker reconcilable with sync-delivered updates (sync can close ranges).
4. Keep feature-flag friendliness with `RealtimeV2` sync config (`setEnableSyncMessageUpdates` path).

Reference Inline sync files:

- `server/src/functions/updates.getUpdates.ts`
- `server/src/modules/updates/sync.ts`
- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift`
- `apple/InlineKit/Sources/RealtimeV2/Sync/Storage/GRDBSyncStorage.swift`
- `apple/InlineKit/Sources/InlineKit/Api.swift`

### Phase 9: Tests and telemetry

1. InlineKit tests:
   - messageId window invariants
   - bidirectional pagination invariants
   - gap-range merge/split behavior
   - unread separator placement
2. Server tests (if API changed):
   - around-target ordering and boundaries
   - directional pagination no-overlap guarantees
3. macOS manual matrix:
   - clear cache chat open with unread anchor
   - large gap recovery without full reset
   - fallback hard reset path
4. Telemetry counters:
   - gap detected
   - gap repaired
   - hard reset executed
   - anchor bootstrap time

## File Touch Plan

- `apple/InlineMac/Views/ChatView/ChatViewAppKit.swift`
- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`
- `apple/InlineMac/Views/Chat/State/ChatState.swift` (optional: richer jump reason payload)
- `apple/InlineMac/Views/MessageList/MessageTableRow.swift` (or new separator cell file)
- `apple/InlineMac/Views/EmbeddedMessage/EmbeddedMessageView.swift` (route jump reason/source)
- `apple/InlineMac/Views/Message/MessageView.swift` (route jump reason/source)
- `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift`
- `apple/InlineKit/Sources/InlineKit/ViewModels/FullChat.swift` (bootstrap orchestration)
- `apple/InlineKit/Sources/InlineKit/ViewModels/UnreadManager.swift` (if read timing needs adjustment)
- `apple/InlineKit/Sources/InlineKit/Transactions2/*` (around-target + directional paging transactions)
- `server/src/db/models/messages.ts` (reuse helper already exists)
- `server/src/functions/*` + `server/src/realtime/handlers/*` (around-target + forward paging contract)
- `proto/*` + generated outputs (if contract changes)
- `apple/InlineKit/Sources/RealtimeV2/Sync/*` (compat hooks, if needed)

## Key Risks

1. Regressing iOS/shared consumers if default `MessagesProgressiveViewModel` semantics change.
2. Premature read marking when initial anchor is not bottom.
3. Separator/diff index bugs with mixed day + unread separator rows.
4. Spinner gating deadlock if anchor availability signal is not robust.
5. Gap tracker and sync updates diverging if merge/reconciliation rules are weak.
6. Remote pagination overlap causing duplicate rows if API cursors are ambiguous.

## Clarifications Needed Before Implementation

Resolved decisions from Mo (2026-02-18):

1. Manual unread mark only (`unreadMark == true`, `unreadCount == 0`) must not create unread separator/anchor.
2. Initial unread placement: near top with padding.
3. Gap policy default: lazy fill ranges.
4. Anchor loading UX: spinner only while connected/authed and fetch in progress; offline should not block with spinner.
5. Rollout scope: new UI only (shared logic remains shared where already common).
6. RPC direction: explicit mode fields in a single existing history RPC path.
7. Proto host for mode field: `GetChatHistoryInput`.

No blocking decisions remain before implementation.

Default implementation semantics (adjust only if issues appear during implementation):

1. Cursor boundaries:
   - `older(before_id)`: strictly `< before_id`
   - `newer(after_id)`: strictly `> after_id`
   - `around(anchor_id, include_anchor=true)`: includes anchor row
2. Result ordering:
   - chronological ascending for UI merge path
3. Spinner gating:
   - show blocking spinner only when logged-in + realtime connected + anchor fetch in-flight
   - no blocking spinner while offline/disconnected
4. Future saved-scroll precedence:
   - `explicit target` -> `saved scroll position` -> `unread anchor` -> `latest`

## Scope, Risks, Trade-Offs (for approval)

Scope of changes:

1. Proto + server history handlers/functions/models (new/extended history RPCs).
2. InlineKit transactions + progressive VM window/gap logic.
3. macOS new UI message list/table row modeling (unread separator + anchor scroll).
4. Chat open loading state orchestration (spinner-gated unresolved anchor).
5. Tests across server + InlineKit invariants + macOS manual matrix.

Main risks:

1. Scroll-anchor regressions when rows insert above/below while maintaining viewport.
2. Duplicate or missing messages if cursor semantics are inconsistent.
3. Gap tracker divergence from sync-applied updates if reconciliation is weak.
4. Spinner-until-success can block chat indefinitely under persistent network/server failure.
5. Shared model/viewmodel changes can leak behavior to non-target surfaces if not carefully gated.

Trade-offs with chosen decisions:

1. Spinner until success:
   - Benefit: no stale incorrect content.
   - Cost: potential long blocking while connected; mitigated by no blocking spinner when offline/disconnected.
2. Lazy gap fill:
   - Benefit: avoids heavy cache resets and large immediate fetches.
   - Cost: temporary non-contiguous history until gaps are filled.
3. Near-top unread anchor:
   - Benefit: preserves context above unread boundary.
   - Cost: needs guardrails to avoid immediate auto-trigger of older pagination.
4. New UI only:
   - Benefit: reduces rollout risk.
   - Cost: requires strict gating in shared layers to prevent accidental legacy behavior shifts.

## Production Readiness

Not production-ready yet. This is a scoped implementation plan; code changes and validation are still required.
