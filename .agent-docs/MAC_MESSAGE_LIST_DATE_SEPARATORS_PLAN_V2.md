# macOS Message List: Date Separators (NSTableView) — Plan v2

This is a second-pass plan incorporating recent review feedback and a bias toward correctness and maintainability over “clever diffing”.

## Goal

Show a compact (“tight”) date separator badge in the macOS message list (`NSTableView`) that:

- appears **before the first message** (for the first day currently shown)
- appears **between messages** when the day changes
- uses the **user’s current locale/calendar/time zone** for “day” boundaries
- is implemented in **AppKit** (no SwiftUI)

## Relevant Files (starting points)

macOS message list (AppKit):

- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift` (table view, scroll logic, update application)
- `apple/InlineMac/Views/MessageList/MessageTableRow.swift` (`MessageTableCell`)
- `apple/InlineMac/Views/Message/MessageViewTypes.swift` (`MessageViewProps` / `MessageViewInputProps`)
- `apple/InlineMac/Views/MessageList/ScrollToBottomButtonHostingView.swift` (existing example of view composition; do not use SwiftUI for separators)

Separator row view (AppKit):

- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift` (currently defines `DateSeparatorTableCell` at file scope; can be extracted later if desired)

Upstream data / change sets:

- `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift` (`MessagesProgressiveViewModel`, `MessagesChangeSet`)

## General Instructions (for the feature)

- Prefer correctness and scroll stability over aggressive incremental diffing; `reloadData()` + minimal anchoring is acceptable when unsure.
- Keep the “message-id scroll anchor” usage **minimal**: only wrap `reloadData()` fallback paths, ideally behind a local feature flag defaulting to off until validated.
- Do not use SwiftUI for the separator view (implement an AppKit `NSView` row).
- Keep the separator layout tight (small fixed height, capsule badge), and ensure separator rows are non-selectable.
- Never assume `row == messageIndex` after separators exist; always convert via `rowItems` and stable IDs.
- Be conservative about touching unrelated scroll heuristics in `MessageListAppKit`; aim to preserve current behavior.

## Current State (what we’re changing)

- `MessageListAppKit` (`apple/InlineMac/Views/MessageList/MessageListAppKit.swift`) is an `NSTableView` where **row index == message index**.
- `MessagesProgressiveViewModel.MessagesChangeSet` drives table updates, but its `indexSet` is **not reliable enough** to depend on for structural table diffs (e.g. `.added` currently returns a single index in some cases).
- Several features assume message-index rows:
  - `message(forRow:)`, `messageProps(for:)`, grouping (`isFirstInGroup`), height calc, scroll-to-message highlight, etc.

## Recommended Approach (Option B, but robust)

Introduce a *flat* table row model (`rowItems`) that interleaves:

- **day separator rows** (start-of-day badge)
- **message rows** (existing message cell)

Then adapt all table plumbing and update logic to operate on `rowItems` rather than `messages` directly.

### Key design decision: stable identifiers, not message indices

**Do not store message indices in `RowItem`**. Indices shift on prepend/delete and make “suffix/prefix detection” brittle.

Instead store stable IDs:

```swift
private enum RowItem: Equatable, Hashable {
  case daySeparator(dayStart: Date) // Calendar.startOfDay(for:)
  case message(id: Int64)           // FullMessage.id (stable list identity)
}
```

Alongside `rowItems`, maintain maps rebuilt atomically:

- `messageIndexById: [Int64: Int]` → locate `FullMessage` in `viewModel.messages`
- `rowIndexByMessageId: [Int64: Int]` → locate the corresponding table row for scroll/highlight/reload

## Building `rowItems`

Define:

- `calendar = Calendar.autoupdatingCurrent` (not a cached `Calendar.current`)
- `dayStart(for messageDate)` = `calendar.startOfDay(for:)`

Algorithm:

- If `messages.isEmpty` → `rowItems = []`
- Else:
  - Insert `.daySeparator(dayStart(firstMessage))`
  - Insert `.message(id: firstMessage.id)`
  - For each subsequent message:
    - If `dayStart(curr) != dayStart(prev)` → insert `.daySeparator(dayStart(curr))`
    - Insert `.message(id: curr.id)`

This guarantees “separator before first message” and “between days”.

## Separator UI (AppKit-only, tight)

Add a new view type for separator rows, e.g.:

- `apple/InlineMac/Views/MessageList/DateSeparatorTableCell.swift`

Suggested structure:

- root `NSView`
- centered badge container:
  - `NSVisualEffectView` (material blur) OR theme-colored `NSView`
  - `NSTextField(labelWithString:)` inside, single line
  - fixed height (tight), capsule radius = height/2, continuous corners

Behavior:

- `configure(dayStart: Date)` sets string:
  - Today / Yesterday via `calendar.isDateInToday(...)`, `isDateInYesterday(...)`
  - else `DateFormatter` (cached) or `Date.FormatStyle`
- Keep it lightweight: constraints set once, only update label string on configure.

Row selection:

- separators should be non-selectable (implement `tableView(_:shouldSelectRow:)` to return `false` for separator rows).

## Table Integration

Update `MessageListAppKit` to use `rowItems` everywhere:

- `numberOfRows(in:)` → `rowItems.count`
- `tableView(_:viewFor:row:)`:
  - `.daySeparator` → dequeue/configure `DateSeparatorTableCell`
  - `.message` → dequeue/configure existing `MessageTableCell` (but fetch `FullMessage` via `messageIndexById`)
- `tableView(_:heightOfRow:)`:
  - separator → constant `DateSeparatorTableCell.height`
  - message → existing `MessageSizeCalculator` path (no behavioral changes)

Fix all helper methods that currently assume row==message index:

- `message(forRow:)` should return nil for separator rows.
- `messageProps(for:)` must accept a **message row** (or resolve row → message ID → message index).
- Grouping (`isFirstInGroup`) must operate in **message space**:
  - find message index for current message
  - compare to previous message index (not previous row)

Scroll/highlight:

- `scrollToMsgAndHighlight` must map `msgId` → `rowIndexByMessageId[msgId]`.

## Update Strategy (pragmatic and safe)

### Core principle

Always rebuild `rowItems` from `viewModel.messages`, then choose the safest UI update:

- **If structural change is simple and provably safe** → incremental insert/remove/reload
- Otherwise → `tableView.reloadData()` + preserve scroll as needed

### Minimal “message-id scroll anchor” (only for reload fallbacks)

`MessageListAppKit` already has scroll-preservation helpers oriented around bottom anchoring (e.g. `maintainingBottomScroll(...)` and `anchorScroll(to: .bottomRow)`). Those are good for many cases, but `reloadData()` can still produce subtle jumps when row heights change and/or the inserted content isn’t a pure prefix/suffix.

To reduce risk without overcomplicating updates, add a **small, optional** helper that anchors to the first visible *message* row by stable message id:

- **Capture:** find the first visible row that is a `.message(id:)`, record:
  - `anchorMessageId`
  - the message row’s `rect(ofRow:)` and its offset relative to the table’s visible rect (e.g. `rowRect.minY - tableView.visibleRect.minY`)
- **Restore (after reload):** look up `rowIndexByMessageId[anchorMessageId]`, compute the new `rowRect.minY`, and scroll such that the row lands at the same offset.

Usage policy (keep minimal until proven):

- Only wrap the **reload fallback paths** (cases where `oldRowItems`/`newRowItems` are not pure prefix/suffix and we choose `reloadData()`).
- Do **not** use it for the common “append at bottom” case.
- Consider guarding with a feature flag (off by default) until it’s validated on real chats.

### “Provably safe” structural checks

Let `old = oldRowItems`, `new = newRowItems`.

We only do incremental inserts/removes when:

1) **Pure suffix insertion**: `new.starts(with: old)` and `new.count > old.count`
   - inserted rows are `old.count..<new.count`
2) **Pure prefix insertion**: `new.ends(with: old)` and `new.count > old.count`
   - inserted rows are `0..<(new.count - old.count)`
3) **Pure suffix removal**: `old.starts(with: new)` and `old.count > new.count`
4) **Pure prefix removal**: `old.ends(with: new)` and `old.count > new.count`

Anything else (including mid-list changes or mixed insert+delete) falls back to reload.

This avoids implementing a fragile general-purpose diff algorithm for interleaved rows.

### Handling `MessagesChangeSet` variants

We treat the change set mainly as a *hint for animation / scroll behavior*, not as the source of truth for row indices.

- `.reload` → rebuild + `reloadData()`
- `.added` / `.deleted`:
  - rebuild
  - if pure prefix/suffix change → use `insertRows`/`removeRows` on the computed ranges
  - else → `reloadData()`
- `.updated(updatedMessages, _, animated)`:
  - rebuild
  - if `oldRowItems == newRowItems` (no structural changes) → reload rows for the affected message IDs via `rowIndexByMessageId`
  - else → `reloadData()`

### Scroll preservation

Preserve existing behaviors:

- When user is at bottom and new messages arrive: keep “scroll to bottom” logic.
- When reloading or inserting at top (load older): use existing `maintainingBottomScroll` / `anchorScroll(to:)` utilities.

Specifically:

- For “load older” path: note that in `rowItems` it’s often **not** a pure prefix insert (because the existing first day separator stays, and new same-day messages are inserted after it). Prefer a small, safe insert strategy:
  - rebuild `rowItems`
  - compute inserted row indexes by “new items not in old sets” (message stable ids + dayStart values)
  - `insertRows(at:)` with that `IndexSet` under the existing scroll-preserve wrapper
  - fall back to `reloadData()` only if the counts don’t line up
  If reload feels jumpy, optionally enable the minimal “message-id scroll anchor” wrapper for this reload path as well (still behind the same feature flag).

## Edge Cases / Correctness Checklist

- Empty list: no rows
- Single message: `[separator, message]`
- Many messages same day: one separator at top only
- Day boundary: exactly one separator for each day in the loaded window
- Deleting the last message of a day removes that day’s separator
- Updating a message’s date across days updates separators correctly (will likely trigger reload fallback)
- Time zone / locale / calendar changes:
  - separators should follow the user’s current settings
  - optional follow-up: observe `.NSSystemTimeZoneDidChange`, `.NSCurrentLocaleDidChange`, `.NSCalendarDayChanged` and call `applyUpdate(.reload(animated: false))`

## Implementation Steps

1) Add `RowItem`, `rowItems`, and maps to `MessageListAppKit`
2) Implement `rebuildRowItems()` using `Calendar.autoupdatingCurrent`
3) Add `DateSeparatorTableCell` (AppKit-only, tight pill)
4) Update table datasource/delegate methods to use `rowItems`
5) Fix message-space helpers (props, grouping, first/last, height cache lookups)
6) Update `scrollToMsgAndHighlight` + any other msgId→row lookups
7) Add optional “message-id scroll anchor” helper (feature-flagged; used only around reload fallbacks)
8) Replace `applyUpdate` row operations with the rebuild + safe prefix/suffix checks + reload fallback (optionally wrapped by the anchor helper)
9) Adjust `loadBatch(at: .older)` to rebuild + insert new rows via “set-based inserted indexes” (message ids + dayStart), otherwise reload under scroll-preserve (optionally wrapped by the anchor helper)

## Notes on scope

- No `NSOutlineView` / “sections”.
- No SwiftUI embedding.
- No attempt to fully general-diff interleaved rows; correctness-first with conservative fallbacks.

## Current Implementation Notes (as of this document)

These notes help the next agent quickly correlate this plan with the code once implemented.

- Row model + mapping:
  - `RowItem` is defined in `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`.
  - The table drives off `rowItems` and maps stable ids via `messageIndexByMessageStableId` and `rowIndexByMessageStableId`.
- Separator view:
  - `DateSeparatorTableCell` is currently defined at file scope in `apple/InlineMac/Views/MessageList/MessageListAppKit.swift` (can be extracted later if needed).
  - Fixed row height is `DateSeparatorTableCell.height` (tight).
- Updates:
  - `applyUpdate(...)` snapshots `oldRowItems`, rebuilds, then uses only provably-safe prefix/suffix insert/remove; otherwise reload fallback.
  - The reload fallback can optionally use a minimal message-id anchor (currently behind `feature_messageIdAnchorOnReloadFallback`, default `false`).
- Load older:
  - `loadBatch(at: .older)` rebuilds row items and computes inserted row indices by comparing against the old sets (message stable ids + dayStart values), then inserts those indices; falls back to `reloadData()` if counts don’t line up.

