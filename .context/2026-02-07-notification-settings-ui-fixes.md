# Notification Settings UI Fixes (macOS + iOS) (2026-02-07)

From notes (Feb 4-5, 2026): "fix notification settings UI fixes".

This is about the user-facing settings UI, not notification delivery correctness (covered elsewhere).

Related correctness spec:
- `/.agent-docs/2026-02-07-notifications-title-clearing-per-chat-settings.md`

## Goals

1. Notification settings UI is understandable and consistent across platforms.
2. No confusing duplicate modes or inconsistent labels/icons.
3. Settings changes apply immediately and are persisted.

## Current State (macOS)

1. Sidebar footer contains a popover button that controls global notification mode.
2. Modes include `all`, `mentions`, `onlyMentions`, `none` (and a disabled Zen branch).
3. There is an extra `disableDmNotifications` behavior tied to `onlyMentions`.

Key file:
- `apple/InlineMac/Views/NotificationSettingsPopover/NotificationSettingsPopover.swift`

## Spec

### 1. Simplify and rename modes

Recommended global modes:
1. All messages
2. Mentions + DMs
3. Mentions only
4. None

Rules:
1. Each mode has a clear description.
2. DMs behavior is explicit in the label, not hidden in a secondary boolean.

### 2. Remove or fully implement Zen

1. If Zen is not shipping, remove the UI stub to reduce confusion.
2. If Zen is shipping, it needs:
3. A server-backed rules model.
4. A clear privacy statement.
5. A stable UI with obvious “Done” behavior.

### 3. Visual polish

1. Ensure the icon transitions don’t feel jumpy.
2. Ensure popover padding and item hit targets are consistent.
3. Ensure selection highlight is obvious in both light and dark mode.

### 4. iOS parity

1. Ensure iOS exposes the same global modes with the same semantics.
2. If iOS already has a different settings screen, map it to the same underlying model.

## Implementation Plan

1. Decide the final global modes and remove dead branches.
2. Consolidate mode + DM behavior into one state (avoid hidden toggles).
3. Add a small UI test checklist:
4. Toggle each mode, restart app, confirm persistence.
5. Send a DM and a mention to confirm expected notifications.

## Acceptance Criteria

1. A user can predict what will notify them from the UI labels alone.
2. There are no dead/disabled “mystery” options in the UI.

