# Notifications: Title Fixes + Clearing + Per-Chat Settings (2026-02-07)

From notes (Feb 5-7, 2026): "notifications are not cleared", "fix notification title", "spec out per-chat notification settings", "use hashtag for thread icons without icon in notifications".

This doc covers three related problem classes:
- correctness of notification titles/icons,
- clearing/deduping notifications, and
- per-chat notification settings (spec).

## Goals

- Notifications have the correct title/identity (threads show thread + space context).
- Notifications clear when messages are read, on both iOS and macOS.
- Add a scalable per-chat settings model without breaking existing global settings.

## Non-Goals (For Tomorrow)

- Rebuilding the entire notification system.
- Multi-device perfect clearing for all historical notifications; focus on the common path.

## Current Pipeline (High Level)

Server to iOS:
- APNs are sent for iOS sessions only.
- Notification formatting happens in the notification extension.
Files:
- `server/src/functions/messages.sendMessage.ts`
- `server/src/modules/notifications/sendToUser.ts`
- `apple/InlineNotificationExtension/NotificationService.swift`

Server to macOS:
- macOS uses local notifications created from realtime updates, not APNs.
Files:
- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift`
- `apple/InlineKit/Sources/InlineKit/MacNotifications/MacNotifications.swift`

Clearing:
- iOS has a clear path; macOS effectively does not.
Files:
- `apple/InlineKit/Sources/InlineKit/ViewModels/UnreadManager.swift` (iOS-only cleanup calls)
- `apple/InlineKit/Sources/InlineKit/Notifications/NotificationCleanup.swift`

## High-Confidence Issues

1. macOS notifications are not cleared on read.
- `UnreadManager` calls `NotificationCleanup` under `#if os(iOS)` only.

2. Cleanup matching is brittle due to mismatched userInfo types.
- Cleanup expects `threadId` as String; macOS notifications store threadId as Int64 in userInfo.
- Even if we enable cleanup on macOS, it would not match until we normalize.

3. Thread title parity on iOS is missing space context.
- macOS local notifications can include workspace/space name; iOS APNs payload does not carry it.
- Threads without a title or emoji can appear like DMs.

4. Per-chat notification settings do not exist.
- Only global user notification settings exist.
- No dialog-level override fields exist in schema or proto.

5. Thread/hashtag icon fallback is not explicit.
- Threads without emoji fall back to a letter in iOS.
- There is no explicit "#" fallback for threads.

## Plan A (Tomorrow): Fix Clearing + Title Parity Without Big Refactors

### 1. Make macOS clear notifications on read

- Call `NotificationCleanup.removeNotifications` from `UnreadManager` on macOS as well.
- Update `NotificationCleanup` to accept threadId from userInfo as String or Int/Int64/NSNumber.
- Ensure MacNotifications writes userInfo in a consistent way for future cleanup (prefer storing `threadId` as String, or normalize in cleanup).

Touchpoints:
- `apple/InlineKit/Sources/InlineKit/ViewModels/UnreadManager.swift`
- `apple/InlineKit/Sources/InlineKit/Notifications/NotificationCleanup.swift`
- `apple/InlineKit/Sources/InlineKit/MacNotifications/MacNotifications.swift`

### 2. Fix iOS thread titles by adding explicit display fields to push payload

Add to APNs payload (server-side) for thread chats:
- `threadDisplayTitle`: e.g. "#design"
- `threadSubtitle`: e.g. "Acme Inc" (space name)

iOS extension:
- Prefer `threadDisplayTitle` when building the communication notification title.
- Use subtitle for context.

Touchpoints:
- `server/src/functions/messages.sendMessage.ts`
- `apple/InlineNotificationExtension/NotificationService.swift`

### 3. Add explicit "#" fallback for thread icons when emoji is absent

Server:
- When thread has no emoji, set `threadEmoji = "#"` in notification payload.

iOS extension:
- If `threadEmoji` provided, use it for group avatar rendering.

macOS:
- Decide whether thread notifications should show chat icon or sender avatar.
- If we keep sender avatar, at least include "#" in title for clarity.

## Plan B (Spec): Per-Chat Notification Settings

### Data Model Options

Option 1 (recommended): store per-user per-chat settings on `dialogs`.
Rationale: dialogs are already per-user per-chat. Add columns or JSON fields: `notification_mode` enum (inherit/all/mentions/none), `mute_until` timestamp (optional), `silent` (optional; default false), `updated_at` for merge rules.

Option 2: separate table `dialog_notification_settings`.
- More normalized, but more joins and migration complexity.

### Proto Changes

- Add `Dialog.notificationSettings` (optional) to `proto/core.proto`.
- Add a user-bucket update when dialog settings change (similar to translation settings patterns).

### Server Behavior

Resolve effective settings:
Per-chat override (if present), else global user settings.

Apply in notification evaluator:
- `server/src/modules/notifications/eval.ts`
- `server/src/functions/messages.sendMessage.ts`

### Client UX

- Add in Chat Info:
- Add in Chat Info: Inherit global (default), All messages, Mentions only, Mute (time-based).
- Keep UI consistent across macOS and iOS.

### Rollout (Important)

- Fields should be nullable initially; do not override local behavior on upgrade.
- First explicit user change writes to server; until then, inherit global.

## Testing Plan

Manual:
- macOS: send a message, receive notification, read the message, verify notification clears.
- iOS: verify thread title shows "#thread (Space)" style and not DM-like.

Server tests:
- Per-chat override resolution logic.
- Payload includes new display fields for threads.

## Open Questions

- Do we want silent vs passive notifications (no sound) to be independent from mute?
- Should a per-chat setting support "only when @mentioned" vs "only when notified by AI"? (Probably later.)
