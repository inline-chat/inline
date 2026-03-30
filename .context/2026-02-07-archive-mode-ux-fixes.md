# Archive Mode UX Fixes (ESC Close, Repeat Actions) (2026-02-07)

From notes (Feb 5-7, 2026): "esc in archive mode should close it", "consequtive click on X archive button doesn't work", "pressing multiple archives".

This doc focuses on macOS new sidebar behavior first, and lists iOS follow-ups.

## Goals

- Archive mode is easy to enter/exit.
- ESC exits archive mode back to inbox.
- Archive/unarchive actions are reliable even with repeated clicks (no lost input).

## Current State (macOS new sidebar)

- Archive mode exists and toggles list content (`apple/InlineMac/Features/Sidebar/MainSidebar.swift`).
- Per-item archive/unarchive exists in `apple/InlineMac/Features/Sidebar/MainSidebarItemCell.swift` (action button uses `xmark` for Archive or `chevron.right` for Unarchive; click triggers `DataManager.shared.updateDialog(archived: ...)` in a task).
- There is currently no escape handler for archive mode (only for space picker overlay).

## Likely Root Causes For "Consecutive Click" Failures

- Action button can be clicked multiple times while the first `updateDialog` request is still in flight.
- UI state (`isArchived`) is derived from `item.dialog.archived`, which may not update immediately; repeated clicks can send redundant requests or appear to do nothing.
- Hover tracking areas are disabled during parent scrolling; fast interactions can desync hover/action visibility.

## Plan (Tomorrow)

### 1. Add ESC behavior for archive mode

- In `MainSidebar`, install a key handler (same mechanism as space picker uses) that switches to inbox and consumes ESC when `activeMode == .archive`, otherwise no-op.

Touchpoint:
- `apple/InlineMac/Features/Sidebar/MainSidebar.swift`

### 2. Add an in-flight guard for per-item archive/unarchive

In `MainSidebarItemCell`:
- Add a boolean `isArchivingInFlight`.
- When action button pressed: if in-flight, ignore; else set in-flight true, disable action button (or show spinner), re-enable when task completes.

This makes repeated clicks deterministic.

Touchpoint:
- `apple/InlineMac/Features/Sidebar/MainSidebarItemCell.swift`

### 3. Ensure the UI updates immediately and predictably

Option A (optimistic):
- Immediately update local model to reflect archive state (optimistic UI), then reconcile on response.

Option B (simpler):
- Disable action button until model updates come back from DB observation.

Recommendation: start with Option B (safer and minimal), then add optimistic later if needed.

### 4. iOS follow-ups (separate item later if needed)

From notes:
- "ios archive swipe should go all the way"
- This likely lives in `apple/InlineIOS/Features/ArchivedChatsView.swift` or swipe actions in list rows.

## Acceptance Criteria

1. Pressing ESC while in archive mode returns to inbox immediately.
2. Clicking archive/unarchive action repeatedly does not get stuck or drop actions.
3. Errors surface (toast) when updateDialog fails.

## Test Plan

Manual (macOS):
- Enter archive mode.
- Press ESC, confirm returns to inbox.
- Archive and unarchive a thread rapidly; confirm the result is correct and UI never gets stuck.

## Risks / Tradeoffs

- Adding optimistic UI is higher risk if server rejects; start with in-flight disabling first.
- ESC handling must not conflict with other ESC uses (space picker, modals).
