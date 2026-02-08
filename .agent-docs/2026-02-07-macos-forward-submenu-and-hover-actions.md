# macOS: Forward Submenu + Hover Actions (2026-02-07)

From notes (Feb 3, 2026): "forward submenu in context menu and button on hover?!", "add an on hover trigger for forward ??!".

## Goals

1. Forwarding is fast for common destinations (recent chats/threads).
2. The full forward sheet remains available for complex selection (multiple destinations).
3. Hover actions on a message surface Reply/Forward quickly without right click.

## Current State (What Exists)

1. Message context menu includes a "Forward" item that opens a forward sheet.
2. The forward sheet exists and supports selecting destinations and sending.
3. MessageView has hover tracking and `isMouseInside` state, but does not render hover action UI yet.

Key files:
- Message context menu + forward sheet: `apple/InlineMac/Views/Message/MessageView.swift`
- Forward sheet UI: `apple/InlineUI/Sources/InlineUI/ForwardMessagesSheet.swift`
- Recency sort logic: `apple/InlineKit/Sources/InlineKit/ViewModels/HomeViewModel.swift`

Notes:
1. The menu is built in `createMenu(...)` and rebuilt on demand in `menuNeedsUpdate(_:)`.
2. `forwardMessage()` presents `ForwardMessagesSheet` and supports two paths:
3. Single selection: navigates to destination chat and sets forward context for compose.
4. Multi selection: sends forwards immediately via RPC.

## UX Spec

### 1. Context menu: Forward becomes a submenu

Structure:
1. Forward >
2. Recent destinations (top 5-10)
3. Separator
4. Choose... (opens existing sheet)

Recent destinations rules:
1. Use the user’s recent chats/threads in the current space first.
2. Include Home + other spaces only if “All spaces” is enabled or user explicitly chooses.
3. Exclude the current chat by default (or include as disabled).

### 2. Hover actions on message rows

When mouse hovers a message row (and not scrolling):
1. Show a small action pill near the top-right of the bubble.
2. Buttons:
3. Reply
4. Forward
5. Optional: Add reaction

Interaction rules:
1. Hide actions while scrolling (avoid accidental clicks).
2. Hide when the user opens the context menu.
3. Keep hit targets large enough for trackpad use.

## Implementation Plan

### Phase 1: Forward submenu in context menu (low risk)

1. In `createMenu`, replace the "Forward" item with a submenu.
2. Add a helper `buildForwardSubmenu()` that:
3. Fetches recent destinations (see below).
4. Creates NSMenuItems that call a new selector `forwardToRecentDestination(_:)`.

3. Keep "Choose..." which calls the existing `forwardMessage()` sheet.

### Phase 2: Recent destinations data source

Options:

Option A: reuse Home list data (sorted the same way as everywhere else)
1. Query `HomeChatItem.all()` from the DB when building the menu.
2. Sort using the same logic as `HomeViewModel.sortChats` (pinned, then last activity).
3. Take the first N after filtering.

Why this is better than bespoke DB ordering:
1. It keeps “recent” consistent with the Forward sheet and sidebar ordering.
2. It reduces chance of “why isn’t my most recent chat in the menu?” surprises.

### Phase 3: Hover actions UI

1. Implement a small overlay view (AppKit) in `MessageViewAppKit`.
2. Render it conditionally based on `isMouseInside` and scroll state.
3. Wire Reply to existing `reply()` and Forward to:
4. Default action: open the same Forward submenu (fast) and include “Forward…” to open the sheet.
5. Fallback: if submenu is awkward from hover, open the sheet directly.

Hover pattern references (optional):
1. `apple/InlineMac/Features/Sidebar/MainSidebarHeader.swift`
2. `apple/InlineMac/Views/Sidebar/NewSidebar/SidebarItemRow.swift`
3. `apple/InlineMac/Views/MessageList/ScrollToBottomButtonHostingView.swift`

## Testing Checklist

1. Right click a message:
2. Forward submenu shows recent destinations and Choose...
3. Selecting a recent destination forwards successfully.
2. Hover a message:
3. Action buttons appear and do not flicker.
4. While scrolling: actions do not appear.
3. Forward sheet still works.

## Acceptance Criteria

1. Forward to a recent destination is one click from context menu.
2. Hover actions improve speed without hurting scrolling or selection.

## Open Questions

1. Should “Forward to recent” send immediately, or open the sheet pre-selected?
2. Should we allow multi-forward from submenu (probably no; keep sheet for multi)?
