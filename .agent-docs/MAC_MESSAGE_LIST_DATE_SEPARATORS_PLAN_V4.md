# macOS Message List (AppKit / NSTableView): Date Separators — Plan v4

This is the next implementation plan to (re-)ship macOS date separators using **Option B** (interleaved row items), with a bias toward **correctness + scroll stability** over clever diffing.

## Prompt / Requirements (ground truth)

- Show date separators in the macOS message list (`NSTableView`) as a small “badge”.
- Separator must appear:
  - **before the first message** (for the first day currently shown), and
  - between messages whenever the **local day** changes.
- Day boundaries must use the user’s **current time zone / calendar / locale**.
- **No SwiftUI** for separators (AppKit-only).
- Keep scroll behavior **exactly as before**: do not add competing scroll preservation mechanisms.
- Prefer **correctness and simplicity**; if diffing gets complicated, use `reloadData()`.
- Preserve smooth animations where feasible (single-message delete animation was called “unacceptable” when lost).

## Scope / Non-goals

- Only macOS message list (no iOS changes).
- No “sections” (`NSTableView` sections/header-views are awkward and not worth it here).
- No new “scroll anchor by message id” systems; use existing scroll-at-bottom behavior only.
- Avoid touching unrelated view/gesture code (keep changes isolated to message list).

## Relevant Files (starting points)

macOS message list:

- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift` (data source, delegate, update application, scroll logic)
- `apple/InlineMac/Views/MessageList/MessageTableRow.swift` (`MessageTableCell`)
- `apple/InlineMac/Views/Message/MessageViewTypes.swift` (`MessageViewProps` / `MessageViewInputProps`)

Upstream change sets:

- `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift` (`MessagesProgressiveViewModel.MessagesChangeSet`)

Potentially affected helpers (only if they assume row==message-index):

- search in `apple/InlineMac/Views/MessageList/MessageListAppKit.swift` for: `message(forRow:)`, `messageProps(for:)`, `scrollToMsgAndHighlight`, `loadBatch(at:)`, `heightOfRow`, `shouldSelectRow`

## Chosen Approach (Option B): interleaved `rowItems`

### Why Option B

- Keeps UI composition simple (a separator is “just another row”).
- Avoids `NSTableView` section complexity.
- Avoids entangling separator layout into message cells.
- Makes “separator before first message” trivial and reliable.

### Core model

Add to `MessageListAppKit`:

- `RowItem` enum:
  - `.daySeparator(dayStart: Date)` where `dayStart = Calendar.autoupdatingCurrent.startOfDay(for:)`
  - `.message(id: Int64)` where `id = FullMessage.id` (stable identity)
- `rowItems: [RowItem]`
- stable-id maps (rebuilt atomically from `viewModel.messages`):
  - `messageIndexByMessageStableId: [Int64: Int]` (stableId → index in `viewModel.messages`)
  - `rowIndexByMessageStableId: [Int64: Int]` (stableId → row index in `rowItems`)
  - `dayStartsInRowItems: Set<Date>` (which day separators currently exist)

**Rule:** after this change, never assume `row == messageIndex`.

## Building `rowItems` (correctness rules)

Implement `rebuildRowItems()` in `MessageListAppKit`:

- Use `let calendar = Calendar.autoupdatingCurrent` (not cached `Calendar.current`).
- Iterate `viewModel.messages` in chronological display order.
- For each message:
  - compute `dayStart = calendar.startOfDay(for: message.message.date)`
  - if it’s the first message, or `dayStart != previousDayStart`:
    - append `.daySeparator(dayStart: dayStart)`
    - record `dayStart` into `dayStartsInRowItems`
  - append `.message(id: message.id)`
  - update both maps for the stable id.

Guarantees:

- First visible day always has a separator “header” row.
- Day changes are based on the user’s current timezone/calendar.

## UI: Date separator row (AppKit-only, tight)

Implement `DateSeparatorTableCell: NSView` (prefer keeping it in `MessageListAppKit.swift` initially to avoid Xcode project file edits):

- Fixed height (tight; ~26–30 points).
- Centered capsule:
  - `NSVisualEffectView` (material like `.underWindowBackground` or similar used elsewhere)
  - `NSTextField(labelWithString:)` inside with small font and secondary label color.
  - Continuous corners (`wantsLayer = true`, `cornerCurve = .continuous`) and `cornerRadius = height/2`.
- Configure method:
  - Accept `dayStart: Date`
  - String rules:
    - `calendar.isDateInToday(dayStart)` → “Today”
    - `calendar.isDateInYesterday(dayStart)` → “Yesterday”
    - else → localized short date (no time), e.g. `dayStart.formatted(date: .abbreviated, time: .omitted)`

Interaction rules:

- Separator rows must not be selectable:
  - implement `tableView(_:shouldSelectRow:)` to return `false` when `rowItems[row]` is `.daySeparator`.

## Table view wiring changes (MessageListAppKit)

### Data source

- `numberOfRows(in:)` returns `rowItems.count` (not `messages.count`).

### Delegate: view creation

In `tableView(_:viewFor:row:)`:

- Switch on `rowItems[row]`:
  - `.daySeparator(dayStart)` → dequeue/create `DateSeparatorTableCell`, call `configure(dayStart:)`
  - `.message(id)` → resolve `messageIndex = messageIndexByMessageStableId[id]`, then configure existing `MessageTableCell` using `messages[messageIndex]`.

### Delegate: heights

In `tableView(_:heightOfRow:)`:

- `.daySeparator` → return `DateSeparatorTableCell.height`
- `.message` → existing `MessageSizeCalculator` based height logic

### Helpers that must be made “separator-aware”

Audit / update functions that take a row and assume it’s a message:

- `messageStableId(forRow:)` → return nil for separators
- `messageIndex(forRow:)` → map via stable id
- `message(forRow:)` → return nil for separators
- `messageProps(for:)`:
  - must resolve `messageIndex` for the row (message-only)
  - grouping logic (`isFirstInGroup`, `isFirstMessage`, etc.) must operate in **message-index space**, not row space

Scroll-to-message:

- `scrollToMsgAndHighlight(_:)` must find the correct **message row** via stable id → row index map.

## Update logic in `applyUpdate` (simple and safe)

### Principle

- Always rebuild `rowItems` from `viewModel.messages` first.
- Only do incremental NSTableView operations for **provably correct** cases.
- Anything mixed/uncertain → `reloadData()` (and only the existing “if at bottom, scroll to bottom” behavior).

### What to snapshot before rebuild

- `oldRowItems`
- `oldRowCount`
- `oldRowIndexByMessageStableId` (for delete animations)
- (optional) “was at bottom” / existing `shouldScroll` boolean as currently computed

### Supported incremental cases (keep small)

Added:

- **Pure suffix insertion** (append): `new.starts(with: old)` and `new.count > old.count`
- **Pure prefix insertion** (prepend): `new.suffix(old.count) == old` and `new.count > old.count`

Deleted:

- **Pure suffix removal**: `old.starts(with: new)` and `old.count > new.count`
- **Pure prefix removal**: `old.suffix(new.count) == new` and `old.count > new.count`

Updated:

- Only reload specific rows when `oldRowItems == newRowItems` (no structural changes).
  - Convert message indices from `indexSet` into stable ids → row indices.

Reload:

- `reloadData()` only.

### Single-message delete animation (small, guarded, correctness-first)

Reason: users considered losing single-message delete animation unacceptable, but we still avoid complex diffing.

Guardrails:

- Only attempt this when:
  - expected removed rows is small (e.g. ≤ 40), and
  - deleted message count is small (e.g. ≤ 1–3)
- Compute `removedIndexes` from the *old model*:
  - message row: `oldRowIndexByMessageStableId[stableId]`
  - optionally remove the day separator if that day no longer exists after rebuild:
    - scan backwards from the message row in `oldRowItems` to find the closest `.daySeparator(dayStart:)`
    - if that `dayStart` is not in `dayStartsInRowItems` after rebuild → include that separator row index

Safety checks (mandatory):

- `removedIndexes.count == oldRowCount - newRowCount`
- Create `remainingOldRowItems = oldRowItems` minus removed rows and assert `remainingOldRowItems == newRowItems`

If any check fails → fallback to `reloadData()`.

This keeps the logic readable while being very hard to apply incorrectly.

## Load-more-at-top (prepend) behavior

`MessageListAppKit.loadBatch(at:)` currently inserts rows at the top and preserves scroll.

After interleaving separators:

- The number of inserted rows when loading older messages is no longer equal to “new messages count delta” (separators may be added).
- Update loadBatch insertion logic to derive inserted rows by comparing old/new `rowItems`:
  - preferred: if it’s a pure prefix insertion (`new.suffix(old.count) == old`) then inserted indexes are `0..<insertedCount`
  - otherwise: fallback to `reloadData()` and let the existing scroll maintenance handle it (do not add new scroll logic)

## Scroll behavior constraints (do not regress)

Hard rules:

- Do not add a new scroll anchor or “restore by message id” mechanism.
- Do not change existing “keep at bottom” heuristics.
- For fallback `reloadData()`, only keep the existing behavior: if already at absolute bottom and not user-scrolling, scroll to bottom; otherwise do nothing.

## Manual test checklist (production sanity)

Date separators:

- First message in an empty chat shows a separator above it.
- Multiple messages same day → only one separator.
- Messages across midnight in local time → separator appears between days.
- Locale/timezone changes while app running: separators reflect `Calendar.autoupdatingCurrent` boundaries (validate quickly by changing timezone and reloading chat).

Updates / animations:

- Delete one message mid-list → row removal animates.
- Delete the only message on a day → message row and its day separator row both removed (and animate).
- Delete multiple messages → acceptable to fall back to `reloadData()` (no crashes, no scroll corruption).

Scroll:

- At bottom, new message arrives → stays at bottom (as before).
- Not at bottom, new message arrives → no yank to bottom (as before).
- Load older messages by scrolling to top → no big jumps / no fighting mechanisms.

Stability:

- No crash when clicking/selection hits separator rows.
- Height calculations do not assume row==message index.

## Implementation steps (suggested order)

1) Add `RowItem`, `rowItems`, maps, and `rebuildRowItems()` in `MessageListAppKit`.
2) Switch `numberOfRows`, `viewFor`, `heightOfRow`, and selection logic to use `rowItems`.
3) Update row→message helpers and any feature paths that take a `row` (highlight scroll, props/grouping).
4) Update `loadBatch(at:)` insertion to handle prefix inserts with separators; fallback to `reloadData()` if unsure.
5) Rewrite `applyUpdate` to:
   - snapshot old model
   - rebuild
   - apply only the small safe incremental cases, else reload fallback
   - add the guarded single-message delete animation path
6) Manual test the checklist above.
7) Add minimal inline comments only where logic is non-obvious (especially `applyUpdate` branches and guardrails).

