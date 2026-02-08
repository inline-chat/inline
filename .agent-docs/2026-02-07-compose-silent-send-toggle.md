# Compose "Silent Send" Toggle (Sleep-Time Calm) (2026-02-07)

From notes (Feb 7, 2026): "make it calm to send messages at sleep time to others. eg. a silent toggle in compose".

## Goal

Add a per-message "silent" send option so the sender can intentionally reduce disruption for recipients.

## Behavior Spec (Product)

When a message is sent with `silent=true`:
- Recipients still receive the message normally.
- Notifications should be passive: no sound; no vibration; optionally reduced interruption level (platform-specific).
- Unread counts still increment (this is not a "read" feature).

Non-goals (initial):
- Per-chat quiet hours scheduling.
- Automatically silencing based on time zone.

## UI/UX

macOS:
- Add a toggle in the compose area (icon: bell.slash) near send button.
- Add shortcut: `Option+Enter` to send silently (optional but high leverage).
- Toggle resets after sending (recommended), or persists per chat (decision needed).

iOS:
- Add a long-press on Send button to choose "Send" or "Send Silently".
- Optional: a small persistent toggle in compose when enabled.

## Protocol + Data Model

### Preferred Approach

Persist `silent` on the message record.

Proto:
- Add optional `silent` to message entity (so it survives sync/history).
- Add optional `silent` to `SendMessageInput`.

Server:
- Persist in DB column `messages.silent` (bool default false).
- Include the field in full message encoders.

Clients:
- Display can optionally show an indicator in message meta (optional).
- Notifications logic can consult message.silent.

### Alternative (Lower scope, but weaker)

Only carry `silent` in notification payloads without persisting on message.
- Pros: less schema/proto churn.
- Cons: macOS local notifications are generated from realtime updates, so we still need the flag in update/full message to suppress sound; also history would not preserve intent.

## Notification Semantics (Implementation)

iOS APNs:
- Set `sound` to absent (or `""`) for silent messages.
- Consider APNs payload fields for interruption level if supported by our extension setup.

macOS local:
- When creating `UNNotificationContent`, set `sound = nil` if silent.

Important:
- This should integrate with per-chat notification settings if/when those exist.

## Implementation Plan (Tomorrow-Friendly)

1. Proto changes
- Add `silent` to message and `SendMessageInput`.
- Regenerate outputs.

2. Server changes
- Add DB column (migration) and wire into message create, full message encoding, and push payload generation.

3. Apple clients
- Compose UI toggles (macOS + iOS).
- Use flag when calling send message transaction.
- macOS local notifications: suppress sound when message.silent is true.
- iOS notification extension: suppress sound when payload indicates silent.

4. Tests
- Server: unit test that silent messages produce APNs payload without sound.
- Client: manual test on iOS and macOS.

## Tradeoffs / Risks

- Cross-platform consistency: if we forget one path (local notifications vs APNs), silent will be inconsistent.
- "Silent" should not disable notification banners entirely unless we decide that explicitly.

## Open Questions

1. Should "silent" still show a banner, just without sound? (Recommended yes.)
2. Does the toggle reset after each send, or persist per chat? (Recommended reset per send.)
