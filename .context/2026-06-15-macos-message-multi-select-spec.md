# macOS Message Multi-Select Spec

Date: 2026-06-15
Status: implementation-ready spec, initial state scaffolding started

## Goal

Add chat-local multi-select for messages in the macOS app. The feature should feel native on desktop, preserve existing message interactions, and reuse existing batch-capable forwarding and deletion APIs.

The implementation should be scoped to the macOS chat surface. It should not add server/protobuf contracts and should not change iOS behavior.

## Assumed Product Decisions

These are the defaults from the planning discussion:

- Entry points:
  - `Select Message` in each message context menu.
  - `Cmd`-click on a non-interactive message area.
- Selection mode:
  - Replaces or covers compose with a bottom selection action bar.
  - Selects loaded messages in the current chat only.
  - Excludes date separators, unread separators, and thread parent-anchor rows.
  - V1 selects only sent server-backed messages for forward/delete.
- Actions:
  - `Copy`, `Forward`, `Delete`, `Cancel`.
  - `Copy` remains enabled if at least one selected message has text.
  - `Forward` and `Delete` require selected sent messages with positive protocol message ids.
- Destructive UX:
  - Confirm multi-delete.
  - Single-message delete can keep existing behavior.
- Selection lifetime:
  - Clear selection on route/chat teardown.
  - Clear after starting forward.
  - Keep selection after copy.

## Current Code Map

### Chat Ownership

- `apple/InlineMac/Features/Chat/ChatRouteView.swift` hosts `ChatViewAppKit` through `AppKitRouteViewController`.
- `apple/InlineMac/Views/ChatView/ChatViewAppKit.swift` owns chat-level AppKit children:
  - `messageListVC` and `compose` live as child refs at lines 38-40.
  - `setupChatComponents(chat:)` creates `MessageListAppKit` at lines 293-322.
  - The same method creates `ComposeAppKit` at lines 324-344.
  - Message list fills the whole chat view and compose is bottom constrained at lines 352-363.
  - `clearCurrentViews()` disposes/removes message list and compose at lines 435-456.

This makes `ChatViewAppKit` the right owner for selection action chrome because it already coordinates list and compose.

### Message List Ownership

- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift` owns loaded messages and rows:
  - `chatRows` owns interleaved row data at line 16.
  - `messages` proxies `chatRows.messages` at line 20.
  - row lookup helpers live at lines 199-227.
  - the table is a plain `NSTableView` with native selection visuals disabled at lines 254-285.
  - `selectionHighlightStyle = .none` and `allowsMultipleSelection = false` are set at lines 260-261.
- Table rows include UI-only rows:
  - `ChatRowListViewModel.Row` has `.daySeparator`, `.unreadSeparator`, `.parentMessage`, and `.message` at lines 8-12.
  - current `canSelect(row:)` only returns true for `.message` rows at lines 118-120.
  - `messageStableId(forRow:)` returns ids for `.message` and `.parentMessage` at lines 123-130.

This makes `MessageListAppKit` the right runtime owner for selection state because it knows loaded message order, row mapping, row mutation, and cell reuse.

### Cell/Renderer Boundary

- `apple/InlineMac/Views/MessageList/MessageTableRow.swift` defines `MessageTableCell`.
- `MessageTableCell` hosts either `MessageViewAppKit` or `MinimalMessageViewAppKit` through the private `MessageTableRenderableView` protocol at lines 8-17.
- The cell creates the concrete renderer in `updateContent()` at lines 155-190.
- The cell is reused and reset in `prepareForReuse()` at lines 240-245.
- Message size/layout props are computed in `MessageListAppKit.makeMessageCell(...)` at lines 2114-2173.
- `MessageViewProps` and `MessageViewInputProps` are hashable/codable layout props in `MessageViewTypes.swift` lines 22-65.

Selected visual state should be rendered at the `MessageTableCell` layer, not added to `MessageViewProps`, because selected state is visual-only and must not perturb sizing/cache behavior.

### Update/Recycling Paths

- Local older loads are inserted/reloaded in `MessageListAppKit.loadBatch(...)` at lines 1239-1297.
- Live updates are applied in `MessageListAppKit.applyUpdate(...)` at lines 1316-1482.
- `applyUpdate` already distinguishes insert/remove/reload rows and full reload paths.
- Row size updates use visible `MessageTableCell`s at lines 1668-1699.
- `makeMessageCell` reuses cells and configures message content at lines 2114-2173.
- `viewFor tableColumn` maps row enum cases to separator cells or message cells at lines 2187-2217.
- `dispose()` cancels tasks, removes observers, disposes `chatRows`, and clears delegates at lines 2560-2599.

Selection pruning and visual refresh must hook into these paths without causing table-wide reloads for ordinary toggles.

### Existing Message Interactions

- `MessageViewAppKit` and `MinimalMessageViewAppKit` have duplicated but parallel menu and gesture logic.
- Bubble message gestures:
  - long press and double-click setup at `MessageView.swift` lines 1668-1688.
  - long press shows reactions only when not on an interactive target at lines 1700-1719.
  - double-click ACK reaction avoids text/interactive targets at lines 1722-1780.
  - gesture delegate blocks entity/text/interactive hits at lines 4000-4076.
  - interactive hit testing covers reactions, actions, attachments, media, documents, replies, thread summaries, avatars, and names at lines 4095-4199.
  - text hit detection lives at lines 4202-4231.
- Minimal message menu duplication is visible in `MinimalMessageView.swift` lines 4323-4570.
- Single-message actions in `MessageView.swift`:
  - copy text at lines 2934-2943.
  - delete via `.deleteMessages(messageIds:[...])` at lines 2980-2988.
  - reply at lines 3019-3028.
  - forward via `dependencies.forwardMessages.present(messages:)` at lines 3131-3134.

Selection routing must not break these interactions outside selection mode.

### Existing Batch API Support

- `ForwardMessagesPresenter.present(messages:)` already accepts `[FullMessage]` at `ForwardMessagesPresentation.swift` lines 10-16.
- `ForwardMessagesSheet` accepts `[FullMessage]` at lines 53-67 and supports multi-destination sending when `onSend` exists.
- `ForwardMessagesSheetModel.makeSelection(messages:)` maps messages to `message.messageId` and rejects mixed source chats at lines 173-194.
- `DeleteMessageTransaction` already accepts `[Int64]` message ids and optimistically deletes in one transaction at lines 13-17 and 42-55.

No backend/protobuf work is needed for V1.

### Keyboard/Menu Current State

- The Edit menu currently uses standard text selectors:
  - `copy:` at `AppMenu.swift` lines 237-240.
  - `delete:` at lines 247-250.
  - `selectAll:` at lines 252-255.
- `AppMenu.validateMenuItem` only validates app-level nav/tab items today and otherwise returns true at lines 934-991.
- `KeyMonitor` handles window-scoped escape, arrows, return, paste, and similar custom handlers at lines 40-49 and dispatches them from lines 157-225.

Message selection commands should prefer first-responder methods on a custom table/list responder so the existing Edit menu shortcuts can work without broad app-menu changes.

## UX Specification

### Selection Mode Entry

1. Context menu:
   - Add `Select Message` to the message-level context menu for eligible messages.
   - Place it near existing message actions, after `Forward` or before destructive items.
   - Do not add batch actions to every message menu in V1; use the bottom selection bar as the batch action surface.

2. Pointer shortcut:
   - `Cmd`-click on a non-interactive message area enters selection mode and toggles the clicked message.
   - `Shift`-click outside selection mode may also enter selection mode and select from the clicked message only if there is already a valid anchor. Otherwise it behaves like a normal select.

### Selection Mode Interaction

When active:

- Click an eligible message row to toggle selection.
- `Cmd`-click toggles without changing anchor behavior.
- `Shift`-click selects the contiguous loaded-message range between anchor and clicked message.
- Clicking separators does nothing.
- Clicking interactive message subviews should keep their existing behavior unless product explicitly wants selection mode to swallow all row interactions.
- `Esc` exits and clears selection.
- `Cmd+A` selects all currently loaded eligible messages in the current chat.
- `Cmd+C` copies selected message text.
- `Delete` triggers selected-message deletion.

Anchor rules:

- The first selected message becomes anchor.
- Plain click on an unselected message sets anchor to that message.
- `Cmd`-click toggle:
  - if adding a message and no anchor exists, set anchor to that message.
  - if removing the anchor, set anchor to the first remaining selected id by loaded message order.
- `Shift`-click keeps the existing anchor and replaces or extends selection based on implementation choice below.

Range behavior:

- V1 should replace selection with the range when shift-clicking. This is simpler and matches Finder/List style unless a modifier is also pressed.
- Optional `Cmd+Shift` may add the range to the existing selection if easy, but this is not required for V1.

### Selection Bar

The bottom selection bar replaces or covers compose while selection mode is active.

Contents:

- Left: `N selected`.
- Right or center action row:
  - `Copy`
  - `Forward`
  - `Delete`
  - `Cancel`

Design constraints:

- Fixed height near compose minimum height.
- Use existing semantic colors/tokens; do not introduce a one-off colored bar.
- Avoid material backgrounds. Use the existing compose/window surface style and a subtle top border if needed.
- Use SF Symbols/system images in buttons.
- Keep button sizes stable and avoid text overflow in narrow chat widths.

Behavior:

- On selection activation:
  - hide or disable compose.
  - show the selection bar.
  - update message list bottom inset to the selection bar height.
  - move first responder to the message list/table for keyboard commands.
- On selection exit:
  - remove/hide selection bar.
  - restore compose visibility.
  - restore message list bottom inset to compose's current height.
  - restore compose focus only if compose was focused immediately before entering selection mode.

### Action Availability

For selected messages:

- `Copy`: enabled if at least one selected message has non-empty `displayText`.
- `Forward`: enabled if at least one selected eligible sent message exists. V1 should filter out non-sent messages by preventing them from being selected.
- `Delete`: enabled if at least one selected eligible sent message exists.

V1 eligibility:

- Row must be `.message`, not `.parentMessage`.
- `message.messageId > 0`.
- `message.status == .sent`.

Reasons:

- Sending and failed rows have different semantics (`Cancel`, `Resend`, local cleanup).
- Parent thread anchors are context, not regular selectable timeline messages.
- Positive server ids are required by existing forward/delete APIs.

### Copy Format

V1 copies only text, using translated display text when present through existing `FullMessage.displayText`.

Format:

- Resolve selected messages in loaded timeline order.
- Drop messages with nil/empty trimmed display text.
- Join copied message texts with a blank line.

No sender/date prefixes in V1 unless product requests a transcript-style copy later.

### Forward Behavior

- Resolve selected messages in loaded timeline order.
- Pass `[FullMessage]` to `dependencies.forwardMessages?.present(messages:)`.
- Clear selection immediately after presenting the sheet.

This matches existing forward infrastructure and avoids needing a new completion callback from `ForwardMessagesPresenter`.

### Delete Behavior

- Resolve selected messages in loaded timeline order.
- Confirm when count is greater than one:
  - title: `Delete N messages?`
  - destructive action: `Delete`
  - cancel action: `Cancel`
- Send one `.deleteMessages(messageIds: ids, peerId: peerId, chatId: chatId)`.
- Clear selection after confirmation and send initiation.
- Existing optimistic delete flow should remove rows through publishers/updates.
- Show a toast/log error if send throws.

## Technical Specification

### Add A Pure Selection State Helper

Add:

- `apple/InlineUI/Sources/InlineUI/MessageSelectionState.swift`
- `apple/InlineUI/Tests/InlineUITests/MessageSelectionStateTests.swift`

`InlineUI` is a good home because:

- the macOS app already imports `InlineUI` in `MessageListAppKit`.
- the helper can be platform-neutral and testable through the package.
- `InlineUI` already depends on `InlineKit`, but the helper can avoid requiring `FullMessage`.

Suggested shape:

```swift
public struct MessageSelectionState: Equatable, Sendable {
  public private(set) var isActive: Bool
  public private(set) var selectedStableIds: Set<Int64>
  public private(set) var anchorStableId: Int64?
}
```

Core methods:

- `mutating func begin(with stableId: Int64)`
- `mutating func clear()`
- `mutating func toggle(_ stableId: Int64, orderedIds: [Int64]) -> Set<Int64>`
- `mutating func selectOnly(_ stableId: Int64) -> Set<Int64>`
- `mutating func selectRange(to stableId: Int64, orderedIds: [Int64]) -> Set<Int64>`
- `mutating func selectAll(_ orderedIds: [Int64]) -> Set<Int64>`
- `mutating func prune(validIds: Set<Int64>, orderedIds: [Int64]) -> Set<Int64>`
- `func orderedSelection(in orderedIds: [Int64]) -> [Int64]`

Method return values should identify changed stable ids so `MessageListAppKit` can repaint only affected visible rows.

Keep this helper ignorant of row indexes, `NSTableView`, `FullMessage`, and message status.

### Add Message Selection Runtime To `MessageListAppKit`

Modify:

- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`

State:

- `private var selection = MessageSelectionState()`
- `var onSelectionSnapshotChanged: ((MessageSelectionSnapshot) -> Void)?`

Add a local snapshot type:

```swift
struct MessageSelectionSnapshot: Equatable {
  let isActive: Bool
  let count: Int
  let canCopy: Bool
  let canForward: Bool
  let canDelete: Bool
}
```

Selection helper methods:

- `private func selectableStableIds() -> [Int64]`
- `private func selectableStableId(forRow row: Int) -> Int64?`
- `private func isSelectableMessage(_ message: FullMessage, row: Int) -> Bool`
- `private func selectedMessages() -> [FullMessage]`
- `private func publishSelectionSnapshot()`
- `private func repaintSelection(ids: Set<Int64>)`
- `private func pruneSelectionAfterRowsChanged()`
- `func clearSelection()`
- `func selectMessage(stableId:eventModifiers:)`
- `func copySelectedMessages()`
- `func forwardSelectedMessages()`
- `func deleteSelectedMessages()`
- `func selectAllLoadedMessages()`

Important details:

- `selectableStableIds()` should use `messages` order, not row order. This excludes separators naturally and gives correct forward/copy order.
- `selectableStableId(forRow:)` must reject `.parentMessage` even though `messageStableId(forRow:)` returns a stable id for parent rows.
- `selectedMessages()` resolves against current `messages`, not the database.
- No selection helper may issue DB reads.

Pruning:

- After `chatRows.apply(update)` in `applyUpdate(...)`, prune selected ids against current selectable ids.
- After `syncFromViewModelAfterManualMutation()` in `loadBatch(...)`, prune or at least publish because loaded ids changed.
- After `rebuildRowItems()`/`applyInitialData()`, clear or prune.
- If pruning removes all selected ids, exit selection mode and publish an inactive snapshot.

Repainting:

- For visible rows, call cell-level selection update directly if the cell exists.
- For offscreen rows, selection state will apply next time `makeMessageCell` creates/configures the cell.
- Do not call `tableView.reloadData()` just to toggle selection.
- Do not call `noteHeightOfRows` for selection visual updates.

### Add A Custom Table/Responder Boundary

Prefer a small custom `NSTableView` subclass inside `MessageListAppKit.swift` or a sibling file:

- `MessageSelectionTableView`

Responsibilities:

- Forward selection-relevant clicks to `MessageListAppKit`.
- Implement responder actions:
  - `copy(_:)`
  - `delete(_:)`
  - `selectAll(_:)`
  - `cancelOperation(_:)`
- Validate menu items for these actions when selection mode is active.

Selection responder behavior:

- When entering selection mode, `MessageListAppKit` should call `view.window?.makeFirstResponder(tableView)`.
- `copy(_:)` should only handle selected messages when `selection.isActive`.
- If selection is inactive, let normal responder behavior continue.

Avoid adding broad new global key monitor cases for `Cmd+C`, `Cmd+A`, or delete. The current Edit menu already sends selectors that can route through the first responder.

Esc handling:

- First try `cancelOperation(_:)` on the custom table responder.
- If that is unreliable in practice, add one narrow `KeyMonitor` escape handler while selection mode is active and remove it when selection exits.

### Add Cell-Level Selection Chrome And Click Handling

Modify:

- `apple/InlineMac/Views/MessageList/MessageTableRow.swift`

Add to `MessageTableCell`:

- stored `currentStableId: Int64?`
- stored `selectionContext` or closures:
  - `onSelectionClick: ((Int64, NSEvent.ModifierFlags) -> Void)?`
  - `isSelectionModeActive: (() -> Bool)?`
- visual views:
  - background/overlay view
  - fixed-size checkmark indicator
- methods:
  - `configureSelection(stableId:isActive:isSelected:)`
  - `setSelectionVisual(isActive:isSelected:)`
  - `resetSelectionVisual()`

Click handling:

- Add an `NSClickGestureRecognizer` to `MessageTableCell`, or use a cell `mouseDown` override if the gesture is not reliable.
- Only handle clicks when:
  - selection mode is active, or
  - modifier flags include command, or
  - modifier flags include shift and there is an anchor.
- Before toggling, ask the hosted message renderer whether the click point is interactive/text.

Extend `MessageTableRenderableView`:

- Add `func shouldBlockMessageSelection(at point: NSPoint) -> Bool`.
- Implement in both renderers by delegating to their existing interactive/text hit-test logic:
  - block if `interactiveHitTestResult(point) != nil`.
  - block if `isTextPoint(point)` is true.

This requires making small internal wrappers around existing private logic in both `MessageViewAppKit` and `MinimalMessageViewAppKit`. Keep behavior identical to current long-press/double-click blockers.

Visual requirements:

- Selection background must not change row height.
- Selection checkmark must not push message layout.
- `prepareForReuse()` must clear selected state and callbacks.
- `highlight()` scroll-to-message animation and selected background must not permanently overwrite each other; use separate layers/views instead of relying only on the cell layer background.

### Add Message Context Menu Entry

Modify:

- `apple/InlineMac/Views/Message/MessageView.swift`
- `apple/InlineMac/Views/Message/MinimalMessageView.swift`

Add a selection action bridge to both message renderers:

- Avoid capturing a specific initial message in the closure because cells can reuse a renderer for a different message via `updateTextAndSize`.
- Prefer a context object/closure that accepts the renderer's current `fullMessage`.

Suggested shape:

```swift
struct MessageSelectionActions {
  let canSelect: (FullMessage) -> Bool
  let select: (FullMessage) -> Void
  let isSelected: (FullMessage) -> Bool
  let isSelectionActive: () -> Bool
}
```

`MessageTableCell.updateContent()` passes this through when constructing either renderer.

Menu behavior:

- In `createMenu(...)`, add `Select Message` when `canSelect(fullMessage)` is true.
- The action calls `selectionActions.select(fullMessage)`.
- Do not add batch action menu items in V1.
- For text-view context menus, also include `Select Message` unless it would interfere with native selected-text copy; put it below text-copy entries.

### Add Selection Bar In `ChatViewAppKit`

Add:

- `apple/InlineMac/Views/MessageList/MessageSelectionBar.swift`

SwiftUI or AppKit are both acceptable. A SwiftUI view hosted with `NSHostingView` is enough because this is simple chrome and AppKit owns placement.

Modify:

- `apple/InlineMac/Views/ChatView/ChatViewAppKit.swift`
- `apple/InlineMac/Views/Compose/ComposeAppKit.swift`

`ChatViewAppKit` additions:

- `private var selectionBarHost: NSHostingView<MessageSelectionBar>?`
- `private var selectionBarHeightConstraint: NSLayoutConstraint?`
- `private var wasComposeFirstResponderBeforeSelection = false`
- `private var currentSelectionSnapshot = MessageSelectionSnapshot.inactive`

Wire `messageListVC_.onSelectionSnapshotChanged` before/after assigning `messageListVC`.

On active snapshot:

- install selection bar if missing.
- hide or disable compose.
- update bar content.
- call `messageListVC.updateInsetForCompose(selectionBarHeight, animate: true)`.
- make message list/table first responder.

On inactive snapshot:

- remove/hide selection bar.
- show compose.
- restore list inset to `compose.currentHeight`.
- optionally restore compose focus.

`ComposeAppKit` addition:

- expose `var currentHeight: CGFloat` backed by the current wrapper height.
- update it from `updateHeight(...)`.
- initialize it to the same value as the initial height constraint.

Do not recompute compose height externally in `ChatViewAppKit`.

### Batch Actions

#### Copy

In `MessageListAppKit.copySelectedMessages()`:

- resolve selected messages in `messages` order.
- collect `displayText?.trimmingCharacters(in: .whitespacesAndNewlines)` where not empty.
- join with `"\n\n"`.
- write to `NSPasteboard.general`.
- optionally show a small success toast if existing UX uses copy toasts elsewhere; otherwise keep quiet.

#### Forward

In `MessageListAppKit.forwardSelectedMessages()`:

- resolve selected messages in order.
- guard non-empty.
- call `dependencies.forwardMessages?.present(messages: selectedMessages)`.
- if no presenter exists, log error and show toast rather than reimplementing the old local sheet fallback.
- clear selection after presenting.

This intentionally avoids expanding `ForwardMessagesPresenter` with completion callbacks for V1.

#### Delete

In `MessageListAppKit.deleteSelectedMessages()`:

- resolve selected sent messages in order.
- guard non-empty.
- if count > 1, show `NSAlert` or an existing app confirmation helper.
- after confirmation, call:
  - `try await Api.realtime.send(.deleteMessages(messageIds: ids, peerId: peerId, chatId: chatId))`
- clear selection after starting the task.
- on failure, log with `Log.scoped("MessageListAppKit")` and show error toast.

Use existing RealtimeV2 transaction/RPC path; do not add legacy HTTP methods.

### Selection Snapshot Semantics

`MessageSelectionSnapshot` should derive:

- `isActive`: `selection.isActive`.
- `count`: number of selected ids still resolved in current loaded messages.
- `canCopy`: selected resolved messages contain non-empty `displayText`.
- `canForward`: selected resolved messages are all eligible sent messages and count > 0.
- `canDelete`: same as forward for V1.

If a selected id becomes ineligible after update, prune it.

## Edge Cases

### Loading Older Messages

When older messages are inserted at the top:

- keep current selected ids.
- keep anchor if still selected.
- do not auto-select newly loaded messages.
- `Cmd+A` after loading older should include the expanded loaded set.

### Remote Deletes/Updates

When selected messages disappear:

- prune them after `chatRows.apply(update)`.
- if selection becomes empty, exit selection mode.

When selected messages update:

- if they remain eligible, keep selection.
- if status/id changes make them ineligible, prune.

### Renderer Reuse

Renderer reuse can transform a cell from one message to another without reconstructing the renderer. Selection callbacks must therefore be message-current, not captured by the message passed to the renderer initializer.

### Text Selection

Outside selection mode:

- text selection and native text-view context menus must remain unchanged.

Inside selection mode:

- clicking text should still allow text behavior unless product decides selection mode should swallow text interaction.
- `Cmd+C` should copy selected messages only when the message list/table is first responder. If a message text view owns first responder with selected text, native text copy may still win; this is acceptable if selection mode does not force focus back to the table.

### Message Anchors

Thread parent anchor rows use `.parentMessage` and `MessageInteractionMode.threadAnchor`. They must not be selectable in V1 even though they can resolve to a stable id.

### Multiple Windows/Tabs

Selection state is owned by each `MessageListAppKit` instance. Do not put selection in global navigation or `ChatsManager`.

## Test Plan

### Unit Tests

Add tests in `apple/InlineUI/Tests/InlineUITests/MessageSelectionStateTests.swift`.

Required cases:

- begin selects one id and activates selection.
- toggle adds/removes ids.
- removing the anchor chooses the first remaining id in loaded order.
- select range forward.
- select range backward.
- select range with missing anchor falls back to selecting clicked id.
- select all selects supplied eligible ids only.
- prune removes invalid ids.
- prune clears active state when selection becomes empty.
- ordered selection returns ids in loaded order, not set insertion/order.
- changed-id return values include old and new affected ids.

### Focused Build/Test Commands

For pure helper tests:

```sh
cd apple/InlineUI && swift test
```

After app integration:

```sh
bun run macos:debug
```

Use focused package tests first; run the macOS debug build after touching app targets.

### Manual Verification

Verify both render styles:

- Bubble
- Minimal

Verify message shapes:

- text-only
- long text
- outgoing/incoming
- photo
- video
- document
- voice
- reactions
- action rows
- reply embed
- reply-thread summary
- forwarded message header
- translated message text

Verify interactions:

- right-click `Select Message`.
- `Cmd`-click toggles.
- regular click toggles while selection mode is active.
- `Shift`-click range select.
- `Esc` clears.
- `Cmd+A` selects loaded messages.
- `Cmd+C` copies selected texts.
- `Delete` confirms and deletes multiple messages.
- `Forward` opens existing forward sheet with selected messages.
- switching chats clears selection.
- loading older messages preserves existing selected ids.
- selected visual state survives scrolling offscreen and back.
- scroll-to-message highlight still appears on top of or distinct from selection state.

## Performance Requirements

- Selection toggle must not call `reloadData()`.
- Selection toggle must not recalculate message heights.
- Selection visual must not alter row height or message layout plans.
- Selection state must not trigger DB reads from computed properties or cell render paths.
- Batch actions resolve from already-loaded `messages`; no fetches are required.
- Keep message cells lightweight; defer only action work to button/menu handlers.

## Security And Data Integrity

- No new storage of message text.
- Copy action intentionally writes selected display text to pasteboard, same trust boundary as existing single-message copy.
- Delete uses existing authenticated realtime path.
- Multi-delete confirmation reduces accidental destructive actions.
- Do not expose decrypted secrets or read `.env`; this feature does not require environment access.

## Implementation Order

1. Add `MessageSelectionState` and unit tests in `InlineUI`.
2. Add selection runtime state and snapshot publishing to `MessageListAppKit`, with no UI yet.
3. Add `MessageTableCell` selection visual state and offscreen-safe repaint logic.
4. Add message selection context menu item in both message renderers.
5. Add pointer routing through `MessageTableCell` plus renderer hit-test blockers.
6. Add custom responder/table command handling for copy/delete/select all/cancel.
7. Add `MessageSelectionBar` and `ChatViewAppKit` compose/bar switching.
8. Wire copy/forward/delete actions.
9. Run `cd apple/InlineUI && swift test`.
10. Run `bun run macos:debug` and complete manual verification.

## Known Risks

- AppKit click routing through nested `NSTextView`, media views, reaction views, and gesture recognizers is the main risk. Keep the first implementation narrow and verify all existing interactions manually.
- Message menu code is duplicated between bubble and minimal renderers. Keep V1 changes small and symmetric.
- Clearing selection after forward is simpler but means canceling the forward sheet does not restore selection. This is an accepted V1 trade-off.
- Selecting only loaded messages may surprise users expecting all-history selection. This is safer for V1 and should be documented in behavior.
- Existing toolbar/background WIP currently touches nearby macOS chat files. Implementation should re-read current hunks before editing and avoid reverting unrelated changes.
