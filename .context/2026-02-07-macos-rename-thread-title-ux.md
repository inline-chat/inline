# macOS Rename Thread Title UX (Double-Click, Return, Resizing) (2026-02-07)

From notes (Feb 5-7, 2026): "rename via dbl click", "rename click on thread title", "Return should rename", "chat title prevents window from getting smaller", "fix title jumping up in DMs".

Related planning:
- `/.agent-docs/2026-02-01-chat-rename-plan.md`

## Goals

- Rename is reliable and ergonomic: double-click title edits (Finder-style); Return commits; Escape cancels.
- Title does not force an excessive min window width.
- Rename failure is visible (and does not silently desync UI).
- Works for both space threads and participant-scoped threads, with correct permission checks.

## Current Implementation (What Exists)

- Toolbar title supports: double-click to begin editing; Return commits via `controlTextDidEndEditing`; right-click menu includes "Rename Chat...".
Files:
- `apple/InlineMac/Toolbar/ChatTitleToolbar.swift`

Known limitations:
- If rename API fails, UI has no user feedback (only logs).
- Toolbar layout can still fight window resizing if priorities are wrong in constraints.
- Rename eligibility logic must align with server rules (public threads in spaces vs private threads via participants).

## Proposed Improvements (Tomorrow)

### 1. Make the rename state machine explicit

Add explicit UI state for:
- idle
- editing
- saving
- error (inline message or toast)

Behavior:
- When saving: disable editing controls and show subtle spinner or "Saving..." subtitle.
- On error: revert to previous title and show toast or inline error.

### 2. Tighten keyboard semantics

Ensure these are always true:
- Return commits exactly once.
- Escape cancels (revert to old title) even if focus changes.
- Clicking outside ends editing without committing unless Return was pressed.

Note: `controlTextDidEndEditing` already checks `NSTextMovement.return`; keep this but ensure no double-commit (action + delegate).

### 3. Fix window resizing pressure from the title view

Audit the toolbar item view constraints:
- Confirm title stack has low compression resistance on horizontal, low hugging on horizontal, and truncation enabled.
- Ensure the editor text field does not temporarily increase intrinsic width and block resize.

Primary file:
- `apple/InlineMac/Toolbar/ChatTitleToolbar.swift`

### 4. Align rename eligibility with server-side permissions

Current `isRenameAllowed()` checks:
- public space threads: requires membership in space
- else: requires `chat_participants` membership

Tomorrow:
- Confirm server-side permissions match this and that we enforce at the server too (source of truth).
- If server allows only admins/owners for public threads, reflect it in UI to avoid false affordances.

## Acceptance Criteria

1. Double-click title enters edit mode for threads only.
2. Return commits, Escape cancels, and clicking away cancels.
3. Window can be resized small even with a very long title (title truncates).
4. On rename failure (network/server), user sees an error and title reverts.

## Test Plan

Manual:
1. Rename a thread with a long title; shrink window; confirm truncation.
2. Rename then press Escape; confirm no network call and title unchanged.
3. Rename then press Return; confirm update persists and propagates to sidebar/chat info.
4. Simulate server failure (disconnect network) and confirm error surfaces and title reverts.

## Risks / Tradeoffs

- Editing inside an NSToolbarItem is easy to get wrong with focus/first responder; test carefully.
- If we change permission rules, we must keep UI and server in sync to avoid security leaks.
