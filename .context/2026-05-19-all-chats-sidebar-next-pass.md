# All Chats and Sidebar Next Pass

Date: 2026-05-19

## Goal

Finish the next sidebar and All Chats pass with a tight diff: sidebar row polish, stable open/close behavior, option-click open-in-sidebar, time formatting, and a small experimental Gmail-style All Chats row mode.

## Plan

1. Trace the dialog open/close path end to end:
   - sidebar close action
   - `UpdateDialogOpenTransaction.optimistic`
   - transaction result apply
   - realtime `UpdateChatOpen.apply`
   - sidebar inbox fetch and sort
2. Fix close correctness so an explicit local close is not overwritten by stale server/realtime data.
3. Update sidebar:
   - full-width pinned separator from avatar leading to row text trailing
   - 1 px separator with 6 px vertical spacing
   - animated removals
   - rename All Chats row to Chats and use a clearer symbol
   - add Search above Chats
   - add New Thread at the end of the inbox list
4. Update All Chats:
   - option-click opens the item in sidebar without navigating
   - restore system AM/PM formatting
   - add a filter/menu toolbar item for a compact one-line row experiment
   - keep unread badge aligned to the second line in default two-line rows
5. Run focused tests/build checks and second-pass review.

