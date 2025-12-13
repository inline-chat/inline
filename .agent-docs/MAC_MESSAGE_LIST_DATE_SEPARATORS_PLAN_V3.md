# macOS Message List: Date Separators (NSTableView) — Plan v3 (production)

This is the “final pass” plan for shipping date separators in the macOS message list with minimal risk to scroll + animations.

## Prompt / Requirements (as received)

- Show date separators in the macOS message list (`NSTableView`) as a tight badge.
- Separator must appear **before the first message** and between messages when a **new local day** starts.
- Use the user’s current locale/calendar/time zone (day boundary in local time).
- **AppKit-only** (no SwiftUI).
- Prefer **correctness + simplicity** over clever/complex diffing.
- Avoid new/extra scroll preservation; reuse existing scroll behavior only (prior work had “carefully managed” scroll-at-bottom logic and multiple mechanisms must not conflict).
- Keep usage of any new scroll behavior minimal until verified.

## Relevant Files (starting points)

- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift` (table view datasource/delegate, scroll logic, update application)
- `apple/InlineMac/Views/MessageList/MessageTableRow.swift` (`MessageTableCell`)
- `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift` (`MessagesProgressiveViewModel.MessagesChangeSet`)

## Design Choice (Option B)

Use an interleaved row model in the table’s data source:

- messages as rows (existing)
- date separators as rows (new)

This avoids sections (NSTableView section headers are awkward) and avoids rendering separators “inside” message cells.

### Row model

- `RowItem.message(id: Int64)` where `id` is `FullMessage.id` (stable identity)
- `RowItem.daySeparator(dayStart: Date)` where `dayStart = Calendar.autoupdatingCurrent.startOfDay(for:)`

Maintain these maps rebuilt atomically:

- `messageIndexByMessageStableId: [Int64: Int]` (stableId → index in `viewModel.messages`)
- `rowIndexByMessageStableId: [Int64: Int]` (stableId → row index in `rowItems`)
- `dayStartsInRowItems: Set<Date>` (quick “does this day still exist?” checks)

## Building `rowItems` (correct, simple)

Inside `rebuildRowItems()`:

- `calendar = Calendar.autoupdatingCurrent`
- Iterate `viewModel.messages` in order:
  - compute `dayStart` from `message.message.date`
  - if first message, or day changed from previous: append `.daySeparator(dayStart:)`
  - append `.message(id:)`

This guarantees:

- separator appears before the first message in the list
- separator appears at every local-day boundary

## UI (AppKit-only, tight)

Add a separator row view:

- `DateSeparatorTableCell: NSView` (kept in `MessageListAppKit.swift` for now to avoid Xcode project file changes)
- Layout: centered capsule badge (tight height), `NSVisualEffectView` + `NSTextField`
- Text: “Today”, “Yesterday”, else a short localized date string (no time)
- Separator rows are not selectable (`tableView(_:shouldSelectRow:)` returns `false`)

## Table view integration

Update `MessageListAppKit` to drive from `rowItems`:

- `numberOfRows` → `rowItems.count`
- `viewFor`:
  - `.daySeparator` → `DateSeparatorTableCell`
  - `.message` → existing `MessageTableCell` (resolve message via `messageIndexByMessageStableId`)
- `heightOfRow`:
  - `.daySeparator` → constant `DateSeparatorTableCell.height`
  - `.message` → existing `MessageSizeCalculator` path

Never assume `row == messageIndex` after separators exist; always map via stable IDs.

## Update application strategy (keep it safe)

### Core rule

Always:

1) snapshot `oldRowItems` + `oldRowIndexByMessageStableId`
2) call `rebuildRowItems()`
3) choose the simplest provably-correct table update

### “Provably correct” incremental updates

Use incremental `insertRows` / `removeRows` only for pure prefix/suffix changes:

- Added:
  - pure suffix insertion: `new.starts(with: old)`
  - pure prefix insertion: `new.ends(with: old)`
- Deleted:
  - pure suffix removal: `old.starts(with: new)`
  - pure prefix removal: `old.ends(with: new)`

Otherwise fall back to `reloadData()`.

### Deletion animation (fix regression, minimal diffing)

To keep single-message delete animations acceptable without implementing a general diff:

- Only attempt an “animated mid-list delete” when:
  - expected removed rows are small (≤ ~40)
  - `deletedStableIds.count` is small (≤ 3)
- Compute rows to remove from the old model.

Safety checks before applying animation:

- removed count matches `oldCount - newCount`
- removing those rows from `oldRowItems` yields exactly `newRowItems`

If any check fails → fallback to `reloadData()`.

This restores delete animations while staying conservative.

## Scroll + layout nuances (do not regress)

Do not introduce new scroll preservation mechanisms. Keep existing behavior:

- `shouldScroll` is only true when the user was already at the absolute bottom and not actively scrolling.
- Fallback updates (`reloadData`) must not add new anchoring logic; only keep the existing “if at bottom, scroll to bottom” behavior.

Manual test focus:

- deleting messages while near bottom (should not fight the existing keep-at-bottom mechanism)
- mixed structural changes (separator appearing/disappearing) causing row height recalcs

## Test checklist (manual)

- Delete a single message mid-list → delete animates; if it was the only message for that day, the separator also animates away.
- Delete several messages at once → should not glitch; acceptable to `reloadData()` if uncertain.
- Load older messages by scrolling to top → new rows insert without jumping (existing logic).
- While at bottom, receive new message → stays pinned to bottom (existing logic).

