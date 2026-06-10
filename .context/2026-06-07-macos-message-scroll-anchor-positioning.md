# macOS Message Scroll Anchor Positioning

Date: 2026-06-07

## Summary

Persisting macOS message table scroll position should be built as a general
message-anchor system, not as a raw scroll offset. The same primitive can support:

- saved per-chat scroll position
- loading a chat from the first unread message
- future explicit "open from message" or history-window restores

The core anchor should be a stable message id plus an offset from that message row's
top edge.

```swift
struct MessageScrollAnchor {
  let chatId: Int64
  let messageId: Int64
  let offsetY: Double
}
```

Define the geometry as:

```text
viewportTopY = messageRowTopY + offsetY
```

So `offsetY = 0` places the message top at the viewport top, positive values place
the viewport top inside the message, and negative values allow showing context above
the message, such as an unread separator.

## Current Code Shape

Relevant files:

- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`
- `apple/InlineMac/Views/MessageList/ChatRowListViewModel.swift`
- `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift`
- `apple/InlineMac/Features/Chat/ChatOpenPreloader.swift`
- `apple/InlineMac/Views/ChatView/ChatViewAppKit.swift`
- `proto/core.proto`
- `apple/InlineKit/Sources/InlineKit/Transactions2/GetChatHistoryTransaction.swift`

Important existing behavior:

- `MessageListAppKit.viewDidLayout()` currently performs unconditional initial
  `scrollToBottom(animated: false)` while `needsInitialScroll` is true.
- `ChatOpenPreloader.fetchInitialMessages()` currently fetches the latest local
  messages only.
- `MessagesProgressiveViewModel.loadLocalWindowAroundMessage()` already supports
  local loading around a target message id.
- `ChatRowListViewModel` row indexes are not stable because rows include day
  separators, unread separators, and optional parent-message rows.
- `MessageListAppKit` already has several scroll-preservation mechanisms:
  bottom-distance preservation for prepends, row-index anchoring for resize, and
  top-row anchoring for inset changes.
- `proto/core.proto` already has `GetChatHistoryMode` values for latest, older,
  newer, and around, plus `anchor_id`, `before_id`, `after_id`, `before_limit`,
  `after_limit`, and `include_anchor`.
- The Swift `GetChatHistoryTransaction` wrapper currently only exposes `peer`,
  `offsetID`, and `limit`, so it cannot yet request server-side newer/around
  windows even though the protocol and server handler support them.

## Concrete macOS Implementation Plan

### 1. Add Local Persistent Scroll State

Add an `InlineKit` model, for example `ChatScrollPosition`, and a migration at the
bottom of `InlineKit/Sources/InlineKit/Database.swift`.

Suggested table:

```text
chatScrollPosition
  chatId integer primary key
  messageId integer not null
  offsetY real not null
  updatedAt datetime not null
  schemaVersion integer not null default 1
```

Implementation details:

- create `InlineKit/Sources/InlineKit/Models/ChatScrollPosition.swift`
- conform to `Codable`, `FetchableRecord`, `PersistableRecord`, `TableRecord`,
  `Sendable`, `Equatable`
- expose helpers:
  - `fetch(db:chatId:)`
  - `save(db:chatId:messageId:offsetY:)`
  - `delete(db:chatId:)`
  - `deleteIfStale(db:chatId:messageId:)`
- do not foreign-key `messageId` to `message(chatId, messageId)`
- optionally foreign-key `chatId` to `chat(id)` with `onDelete: .cascade`
- store `offsetY` as `Double` in the model and convert to/from `CGFloat` at the
  AppKit boundary

The row should mean: "when this chat opens normally, restore this message id at
this vertical offset." Absence of a row means latest bottom.

### 2. Add Explicit Initial Position Types

Add small shared types near `ChatOpenPreloader` or in a dedicated macOS message-list
file:

```swift
struct MessageScrollAnchor: Sendable, Equatable {
  let chatId: Int64
  let messageId: Int64
  let offsetY: Double
}

enum MessageListInitialPosition: Sendable, Equatable {
  case latest
  case anchor(MessageScrollAnchor, reason: MessageListInitialPositionReason)
}

enum MessageListInitialPositionReason: Sendable, Equatable {
  case savedPosition
  case firstUnread
}
```

Keep this separate from `ScrollToMessageRequest`. `ScrollToMessageRequest` is an
imperative event for an already-open list; `MessageListInitialPosition` is a
construction-time contract for which window of messages should be loaded and where
the initial viewport should land.

### 3. Extend Prepared Payloads

Change `PreparedChatPayload` in `ChatOpenPreloader.swift`:

```swift
struct PreparedChatPayload: Sendable {
  let peer: Peer
  let chatItem: SpaceChatItem?
  let messagesInitialState: MessagesProgressiveViewModel.InitialState
  let initialPosition: MessageListInitialPosition
  let pinnedMessage: PreparedPinnedMessage?
}
```

`ChatViewAppKit.setupChatComponents` should pass this to `MessageListAppKit`.

### 4. Resolve Initial Position In One Shared Local Resolver

Create a local-only resolver used by both the preload path and the cold path. A
name like `ChatInitialMessageWindowResolver` is clearer than putting everything in
`MessageListAppKit`.

Inputs:

- `peer`
- `chatItem` or resolved `chat`
- `dialog`
- `initialLimit`
- `database`

Output:

```swift
struct PreparedMessageWindow: Sendable {
  let messagesInitialState: MessagesProgressiveViewModel.InitialState
  let initialPosition: MessageListInitialPosition
}
```

Resolution precedence:

1. explicit route-level message target, when such a route exists in the future
2. valid saved `ChatScrollPosition`
3. first unread message, only if unread exists and no saved position exists
4. latest bottom

For the current codebase, explicit message navigation is an event after chat
construction (`ChatState.scrollTo(msgId:)`), not a route construction parameter. So
the first implementation only needs saved position, first unread, and latest.

Saved-position branch:

- read `ChatScrollPosition` by `chatId`
- require `messageId > 0`
- require a local `Message` exists for `(chatId, messageId)`
- fetch a biased local window around that message
- if the message is missing, delete the stale saved position and continue to
  first-unread resolution

First-unread branch:

- require `(dialog.unreadCount ?? 0) > 0`
- require `dialog.readInboxMaxId != nil`
- query local `Message` for the smallest `messageId > readInboxMaxId`
- if found, fetch a biased local window around it and return `.anchor(...,
  reason: .firstUnread)`
- use `offsetY = 0` for the first pass; if the unread separator should remain
  visible above the first unread message, use a small negative offset later
- if not found locally, return latest bottom for this pass

Latest branch:

- use the existing latest-message fetch behavior
- return `.latest`

The first pass must not block chat opening on remote unread fetches. A later pass
can change the progressive view model to delay list construction while fetching the
first unread batch.

### 5. Make Cold Route Restore Work Across App Restart

Prepared payloads are only present for user-initiated preloaded opens:

- `Nav2.requestOpenChat`
- `AppDependencies.Nav3ChatOpenPreloadBridge`

Route restoration and some direct opens construct `ChatViewAppKit` with
`preparedPayload == nil`. Today that path creates `MessageListAppKit` with
`initialState: nil`, which makes `MessagesProgressiveViewModel` load latest
messages and loses saved historical scroll across app restart.

Required fix:

- if `preparedPayload != nil`, use its prepared message window and initial position
- if `preparedPayload == nil`, `MessageListAppKit` or `ChatViewAppKit` must invoke
  the same local resolver before constructing `ChatRowListViewModel`

The least invasive approach is:

- let `MessageListAppKit.init` accept `initialPosition:
  MessageListInitialPosition?`
- if `initialState` and `initialPosition` are nil, synchronously resolve a local
  initial window before assigning `chatRows`
- pass `dialog` or at least `showUnreadAfter` into the resolver so first-unread
  can be considered

This mirrors the current behavior where `MessagesProgressiveViewModel.init` already
does a synchronous local DB read on the cold path. The resolver should remain
local-only and cheap.

### 6. Make Progressive Model Know Whether Initial State Is At Bottom

`MessagesProgressiveViewModel` has a private `atBottom` default of `true`. On a
reload update, `atBottom == true` makes the model discard the current range and load
latest messages:

```text
if atBottom {
  loadMessages(.limit(initialLimit))
} else {
  refetchCurrentRange()
}
```

For saved and first-unread anchors this is a hard conflict.

Required fix:

- extend `MessagesProgressiveViewModel.InitialState` with `initialAtBottom: Bool`
  defaulting to `true`
- set `atBottom = state.initialAtBottom` before subscribing to
  `MessagesPublisher`
- for `.latest`, use `initialAtBottom = true`
- for `.anchor`, use `initialAtBottom = false`

Also set `MessageListAppKit.isAtBottom` and `isAtAbsoluteBottom` to `false` early
for anchor starts, before layout and before any code can call
`scrollToBottom(animated:)`.

### 7. Replace Initial Bottom Scroll With Initial Position Application

In `MessageListAppKit.viewDidLayout`, replace the unconditional initial bottom
branch with:

```text
if needsInitialScroll {
  finalize initial measurement width
  applyInitialPosition()
  schedule one follow-up restore pass if anchor
  needsInitialScroll = false after restore settles
}
```

`.latest` behavior:

- scroll to bottom
- mark messages seen
- run initial unread update exactly like today

`.anchor` behavior:

- resolve `messageId -> stable id -> row`
- restore `rowRect.minY + offsetY`
- do not call `markMessagesSeen()`
- do not call `updateUnreadIfNeeded()` until after geometry reports the user is
  actually at bottom or the last row is visible
- set bottom state false before and after restore

Use a guard flag such as `isApplyingInitialPosition` so bounds changes, resize
maintenance, and persistence do not react while the programmatic restore is in
progress.

### 7.5. Add A Position Lock Until Manual User Scroll

`needsInitialScroll` currently acts as a coarse lock: the list keeps forcing the
desired startup position while viewport width, row heights, toolbar insets, pinned
header height, and compose height are still settling. The anchor implementation
needs the same behavior, but targeted to the selected initial position instead of
always bottom.

Add an explicit lock state:

```swift
private enum PositionLock {
  case none
  case bottom
  case anchor(MessageScrollAnchor, reason: MessageListInitialPositionReason)
}
```

Rules:

- create `.bottom` lock for `.latest`
- create `.anchor(...)` lock for saved-position and first-unread starts
- while locked, layout/height/inset/update paths must preserve the locked target
  instead of using row-index anchors or bottom-distance heuristics
- while locked, do not persist scroll position
- release the lock only when the user manually scrolls or explicitly requests a
  different position

The lock should survive beyond the first `viewDidLayout` pass. It should be
re-applied after:

- initial row-height finalization
- `updateScrollViewInsets`
- compose bottom inset changes
- width-change row-height recalculation
- pinned header height changes
- non-user reloads that preserve the same loaded window

For `.bottom`, re-apply `scrollToBottom(animated: false)` while locked. For
`.anchor`, re-resolve `messageId -> row` and apply `rowRect.minY + offsetY`.

Release triggers:

- `scrollWheelBegan` / `NSScrollView.willStartLiveScrollNotification`
- detected scrollbar drag or other AppKit user scroll gesture, if live-scroll
  notifications are not enough
- scroll-to-bottom button click: release anchor lock and transition toward bottom
- explicit `scrollToMsg` request: replace/release the startup lock and let the
  explicit navigation own the scroll

Do not release the lock for programmatic bounds changes caused by layout, height
recalculation, inset updates, or the lock re-apply itself.

This is the key distinction:

```text
isApplyingInitialPosition = transient guard around one programmatic restore
positionLock = durable startup target, active until user/manual intent
```

Once the lock is released, normal scroll persistence starts. If the user never
manually scrolls away and reaches/stays at bottom, the saved scroll position should
remain cleared.

### 8. Add Message-ID Anchor Helpers In MessageListAppKit

Add reusable helpers:

```swift
private struct VisibleMessageAnchor {
  let chatId: Int64
  let messageId: Int64
  let stableId: Int64
  let offsetY: CGFloat
}
```

Helpers:

- `rowForMessageId(_:) -> Int?`
- `captureTopMessageAnchor() -> VisibleMessageAnchor?`
- `restore(anchor:) -> Bool`
- `restore(messageId:offsetY:) -> Bool`
- `saveCurrentScrollPosition(reason:)`
- `clearSavedScrollPositionIfAtBottom()`

Capture should skip:

- date separators
- unread separator
- parent-message row when the list is a reply thread and the parent is not part of
  the chat's normal message sequence

Prefer the first visible normal `.message` row. If the top visible row is a
separator, scan forward to the next visible normal message and compute the offset
from that message's top.

Coordinate convention:

- use the same document-coordinate visible top for capture and restore
- initially use `tableView.visibleRect.minY`
- before coding, verify whether manual `scrollView.contentInsets.top` means the
  correct user-visible top should instead be `visibleRect.minY +
  scrollView.contentInsets.top`
- whichever convention is selected must be used consistently for both saved
  anchors and first-unread anchors

### 9. Persist Scroll Position Durably

Save on more than disappear:

- debounced from `handleBoundsChange`
- immediately on `scrollWheelEnded`
- when `AppActivityMonitor` becomes inactive
- in `MessageListAppKit.dispose()`

Do not save while:

- `needsInitialScroll`
- `isApplyingInitialPosition`
- `isProgrammaticScroll`
- `isPerformingUpdate`

Save policy:

```text
if effective bottom:
  delete ChatScrollPosition for chatId
else:
  save captured top message anchor
```

`viewDidDisappear` alone is insufficient because `ChatViewAppKit.clearCurrentViews`
calls `messageListVC.dispose()` directly. A debounced write during scrolling plus a
final write in `dispose()` is what makes restart restore reliable.

### 10. Update Scroll Conflict Paths

The following code paths must become anchor-aware or be gated during initial
restore.

`MessageListAppKit.viewDidLayout`

- current conflict: unconditional `scrollToBottom(animated: false)`
- fix: switch on `initialPosition` and drive through `positionLock`

`isAtBottom` and `isAtAbsoluteBottom`

- current conflict: both default to `true`
- fix: initialize to false for anchor starts and let `handleBoundsChange`
  recompute after restore

`updateInsetForCompose`

- current conflict: calls `scrollToBottomWithInset` if `isAtBottom`
- fix: if `positionLock` is active, re-apply the lock target after changing the
  inset; otherwise keep current bottom behavior

`updateScrollViewInsets`

- current conflict: captures row-index `TopAnchorSnapshot`
- first-pass fix: if `positionLock` is active, re-apply the lock target after
  changing insets and skip row-index top anchor restore
- follow-up fix: replace row-index snapshot with message-id anchor

`scrollViewFrameChanged`

- current conflict: maintains `oldDistanceFromBottom`, which can be stale during
  initial restore
- fix: return/re-apply the lock target when `positionLock` is active; also return
  when `isApplyingInitialPosition` or `suppressResizeScrollMaintenance` is true

`recalculateHeightsOnWidthChange`

- current conflict: `anchorScroll(to: .bottomRow)` stores row index
- first-pass fix: if `positionLock` is active, re-apply the lock target after row
  heights change and do not use row-index bottom-row anchoring
- follow-up fix: capture/restore message-id anchor when `maintainScroll` is true

`loadBatch(at: .older)`

- current conflict: `maintainingBottomScroll` preserves bottom distance while
  prepending older rows
- likely okay for first pass after initial restore
- follow-up fix: capture/restore message-id anchor around prepends

`applyUpdate`

- current conflict: `wasAtBottom = isAtAbsoluteBottom`; stale true can scroll to
  bottom on reload/insert
- fix: if `positionLock` is active, preserve/re-apply the lock target and suppress
  `shouldScroll`; also set bottom state false before anchor restore and before
  observing updates if possible

`MessagesProgressiveViewModel.applyChanges(.reload)`

- current conflict: private `atBottom` default true reloads latest
- fix: `InitialState.initialAtBottom`

`FullChatViewModel.refetchChatViewAsync`

- current conflict: cold opens call `getChatHistory(peer:)`, whose apply publishes
  a message reload
- fix: because the progressive model's `atBottom` is false for anchor starts, that
  reload should preserve current range instead of loading latest

### 11. Remote History API Is Not Required For First Pass

For this macOS pass, do not change remote fetching behavior. First unread uses only
locally cached messages and falls back to bottom if the target is not cached.

Future remote work:

- extend `GetChatHistoryTransaction.Context` with `mode`, `anchorID`, `beforeID`,
  `afterID`, `beforeLimit`, `afterLimit`, `includeAnchor`
- use `.historyModeNewer` with `afterID = readInboxMaxId` to find first unread
- use `.historyModeAround` to fetch a durable window around saved/explicit anchors
- delay constructing the message list until the first unread batch is present

## Unifying Existing Anchor Logic

After the initial restore path works, the same message-id anchor helper should
gradually replace row-index and bottom-distance preservation where appropriate:

- loading older messages at top should capture and restore the current visible
  message anchor around the prepend
- width recalculation should restore by message id, not row index
- inset changes can keep using top anchoring but should store message id instead of
  row index

This avoids row-index drift caused by separators and progressive loading.

## Telegram macOS Comparison

Telegram macOS has a stronger scroll architecture in three places:

- scroll intent is a typed part of history loading and table transitions, not a
  separate one-off controller flag. `ChatHistoryLocation` can request initial,
  navigation, search, or explicit scroll windows, and `TableUpdateTransition`
  carries `TableScrollState` through the table merge.
- persisted history position is an anchor, not a raw scroll offset:
  `ChatInterfaceHistoryScrollState` stores a `MessageIndex` plus
  `relativeOffset`. Restore maps that message index back to an entry and applies
  `.top(..., inset: relativeOffset)`.
- initial non-bottom rendering is viewport-shaped. Telegram first inserts enough
  rows around/top of the target to fill the viewport, emits that partial
  transition at the target scroll state, then inserts the remaining rows while
  preserving the visible anchor.

Relevant TelegramSwift references:

- `/Users/mo/dev/telegram/TelegramSwift/Telegram-Mac/ChatHistoryViewForLocation.swift`
  defines `ChatHistoryLocation` and `ChatHistoryViewScrollPosition`.
- `/Users/mo/dev/telegram/TelegramSwift/packages/TGUIKit/Sources/TableView.swift`
  defines `TableScrollState`, `TableUpdateTransition`, stable-id lookup, and
  `saveVisible`.
- `/Users/mo/dev/telegram/TelegramSwift/Telegram-Mac/ChatController.swift`
  converts unread/restored/index positions into table scroll states and performs
  partial first insertion for initial placement.
- `/Users/mo/dev/telegram/TelegramSwift/Telegram-Mac/ChatInterfaceState.swift`
  defines the persisted `MessageIndex + relativeOffset` state.

Gaps to close in our plan:

1. Add an internal scroll-intent primitive for row updates, not only initial
   state. The first implementation can keep `positionLock`, but `applyUpdate`,
   initial reload, prepend, resize, and inset changes should all route through a
   small enum similar in spirit to Telegram's `TableScrollState`:

   ```swift
   enum MessageListScrollIntent {
     case none
     case bottom(animated: Bool)
     case top(messageId: Int64, offsetY: CGFloat, animated: Bool)
     case center(messageId: Int64, animated: Bool)
     case preserveVisible(MessageAnchorSide)
   }
   ```

   This avoids each path inventing its own "if locked then restore" branch.

2. Make first-unread and saved-position windows biased by the requested visual
   placement. Our current plan uses `loadLocalWindowAroundMessage`, whose split is
   roughly balanced. A top-anchor restore wants more messages after the target and
   enough context before it only for the requested offset. Otherwise the first
   unread can land near the viewport bottom or require immediate newer loading.

3. Support newer loading from the macOS AppKit list. `MessagesProgressiveViewModel`
   already has `.newer`, but `MessageListAppKit.loadBatch` currently returns for
   every direction except `.older`. When opening from a historical saved point, the
   user can scroll both older and newer. First pass can still fall back to bottom
   when first unread is not cached, but saved historical restore should not create a
   one-sided list.

4. Formalize row anchor eligibility. Telegram rows expose `canBeAnchor`; unread
   markers, date headers, history holes, and sticky/service rows opt out. Our plan
   currently says to skip specific row types. Add a row-level capability or helper
   so date/unread/parent/service rows cannot accidentally become persisted anchors.

5. Handle grouped/combined rows explicitly. Telegram can map an inner message id
   back to a grouped row stable id through `findGroupStableId`. Inline may not have
   Telegram-style album grouping today, but any future grouped media, parent rows,
   collapsed blocks, or synthetic rows need a `messageId -> row` mapping contract
   that is not just "one message id equals one row index".

6. Clarify persisted-anchor invalidation beyond missing message id. Telegram stores
   a full `MessageIndex` because timestamp/order are part of history positioning.
   Inline's `messageId + offset` is probably enough if message ids are strictly
   monotonic in chat order, but the plan should state the invariant. If order can be
   affected by date edits, local pending ids, imports, or replacements, persist
   message date or a sortable message index too.

7. Decide when to clear a saved historical position on unread entry. Telegram gives
   unread priority before stored scroll state on initial open in the inspected path,
   while our desired product rule is saved position first, unread second. That is a
   deliberate difference, not a bug, but it needs to be documented because unread
   badges and first-unread jumps will otherwise look inconsistent across open paths.

8. Persist on lifecycle points, but avoid persisting startup locks. Telegram saves
   immediate scroll state on window key changes, removal, navigation actions, and
   input-state saves. Our planned debounced bounds write plus dispose write is good,
   but we should also save on window/activity resign-key if cheaply available. Keep
   the guard that no write happens while the startup lock is active.

9. Initial lock remains necessary for Inline even though Telegram does not model it
   the same way. Telegram precomputes row heights and drives one table transition
   with scroll intent, so it has less need for a durable "hold this target while
   layout settles" flag. Inline has several independent AppKit layout/inset/height
   paths, so the lock-before-manual-scroll rule is still correct.

## Risks And Validation

Main risks:

- initial restore jitter from variable row heights settling after first layout
- accidentally marking unread messages as read during first-unread restore
- stale saved anchors after deleted messages or cleared history
- saved offsets inside a message becoming odd after render-style or width changes
- slow DB writes if scroll position is saved too frequently
- cold app/restored-route opens bypassing the prepared payload path
- `MessagesProgressiveViewModel.atBottom` reloading latest after a history refetch
- stale `isAtBottom` causing compose inset changes, update animations, or layout
  passes to snap the view back to bottom
- startup position lock releasing too early, before row heights and insets settle
- startup position lock not releasing on some manual scroll path, such as scrollbar
  dragging or keyboard scrolling
- row-index anchors drifting when unread/date separators are inserted or removed
- first-unread restore immediately marking unread as read if the visible local
  window is short enough that the last row is visible
- top inset/pinned header geometry changing the meaning of "viewport top"

Uncertainty / logic-conflict checklist before coding:

- Confirm the correct visible-top coordinate with current manual
  `scrollView.contentInsets.top`. The code must choose one convention:
  `tableView.visibleRect.minY` or `tableView.visibleRect.minY +
  scrollView.contentInsets.top`. Capture and restore must use the same one.
  Recommended starting point: `tableView.visibleRect.minY`, because current
  `captureTopAnchor` / `restoreTopAnchor` uses raw table visible rect coordinates.
- Confirm whether `MessageListAppKit.init` doing a synchronous local resolver is
  acceptable for cold route opens. This matches the existing cold
  `MessagesProgressiveViewModel` behavior but still runs on the main actor.
  Recommended decision: acceptable for this pass as long as it remains local-only
  and bounded to one initial window.
- Confirm first-unread auto-read behavior when the first-unread local window is
  shorter than the viewport. If last row is visible immediately, current logic may
  mark the chat read. This may be correct if all unread messages are visible, but
  it should be a product decision. Recommended decision: allow read marking only
  when the real latest local row is visible; this matches current bottom-visible
  behavior.
- Confirm saved-position stale fallback: recommended behavior is delete stale saved
  row, then try first unread, then bottom.
- Confirm saved-position clearing semantics: recommended behavior is clear only
  when the user reaches effective bottom, not merely when a new unread message
  arrives.
- Confirm all manual scroll inputs that should release `positionLock`: trackpad,
  mouse wheel, scrollbar drag, keyboard scroll if applicable, and scroll-to-bottom
  button.
- Confirm explicit navigation behavior: current explicit message navigation is an
  event after chat construction, not an initial route parameter. If future deep
  links carry a message id at route construction time, that should outrank saved
  position and first unread.
- Confirm reply-thread behavior: do not persist the parent-message row as a normal
  scroll anchor; persist only real message rows from the thread list.
- Confirm whether `ChatScrollPosition` belongs in shared `InlineKit` despite being
  macOS-only for now. It uses the shared Apple database, so this is probably fine,
  but iOS should ignore it.

Validation checklist:

- open chat with no saved position: still starts at latest bottom
- scroll up, leave chat, reopen: restores the same message and offset
- scroll to bottom, leave chat, reopen: starts at latest bottom
- quit and relaunch with a route-restored chat that had a saved historical
  position: restores the saved position
- open chat with unread messages and no saved position: starts at first unread if
  cached, not bottom
- open chat with unread messages and a saved historical position: restores saved
  position, not first unread
- open chat with unread messages whose first unread message is not cached: falls
  back to bottom for now
- first-unread restore does not immediately clear unread unless bottom is visible
- if first-unread local window is shorter than viewport, behavior matches the
  decided auto-read policy
- prepend older messages preserves the current viewport
- resize window while scrolled up preserves the current anchor
- compose height changes while scrolled up do not snap to bottom
- pinned header appearing/disappearing does not drift the saved anchor
- initial anchor remains locked through first width/height/inset settling and only
  starts saving after manual scroll
- manual scroll releases the startup lock immediately
- deleted anchor falls back cleanly
- row separators do not break restore
- cold route with `preparedPayload == nil` does not ignore saved scroll
- remote `getChatHistory(peer:)` reload during cold open does not replace the
  anchored range with latest messages
- saved position is written before app restart even if the chat view is disposed
  without `viewDidDisappear`

Production readiness depends on focused macOS validation because this path is
latency-sensitive and visually sensitive. There are no new security concerns beyond
the local persistence table, but DB write frequency should be debounced.
