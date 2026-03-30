# macOS multiple notifications — findings

## Summary
- The macOS client can show multiple notifications because there is no dedupe/collapse when posting local notifications.
- The app can receive duplicate updates if both realtime stacks are active (legacy Realtime + RealtimeV2).
- The server can send multiple APNs to macOS if the user has multiple sessions/tokens or duplicate tokens.

## Evidence in repo
- Local notifications are posted with a new UUID each time:
  - `apple/InlineKit/Sources/InlineKit/MacNotifications/MacNotifications.swift`
- Notifications are triggered from both update paths:
  - `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift`
    - `.newMessage` → local notification if mode == all
    - `.newMessageNotification` → local notification if mode != all
- Two realtime stacks can be active in the same app:
  - `apple/InlineKit/Sources/InlineKit/RealtimeHelpers/RealtimeWrapper.swift` (legacy `Realtime.shared`)
  - `apple/InlineKit/Sources/InlineKit/Api.swift` + `RealtimeV2` usage via `Api.realtime`
  - `apple/InlineKit/Sources/InlineKit/Utils/Env.swift` provides both to views
- Server push to macOS sessions occurs in legacy REST path:
  - `server/src/methods/sendMessage.ts` sends APN to every session with `applePushToken`
  - `server/src/db/models/sessions.ts` returns all non‑revoked sessions without dedupe

## Most likely causes of 6–7 notifications
1. Multiple active macOS sessions or duplicate stored push tokens → APNs fan‑out.
2. Duplicate updates applied by both realtime stacks → multiple local notifications.
3. Sync catch‑up + direct updates applied together → repeats (especially if sync is enabled).

## How to confirm quickly
- Check server logs for how many APNs are sent per message (in `sendMessage.ts`).
- Count active sessions/tokens for the user in the DB (macOS clientType).
- Add temporary logging for messageId + update kind in:
  - `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift`
  - `apple/InlineKit/Sources/InlineKit/MacNotifications/MacNotifications.swift`
- See whether duplicates happen when the app is fully closed:
  - If yes: APNs fan‑out is likely.
  - If no: local notifications + duplicate updates are likely.

## Notes
- No changes were made; this file captures investigation results only.
