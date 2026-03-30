# Findings
- Notifications/badge increments come from `UpdateNewMessage.apply` in `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift`; it always increments unread + triggers mac notification with no dedupe.
- Duplicate updates can originate from two likely sources: (1) multiple realtime connections per user/session (server sends updates to all connections), and/or (2) RealtimeV2 sync bucket fetch reapplying `newMessage` updates alongside direct realtime updates when sync message updates are enabled.
- Server `connectionManager.authenticateConnection` does not close existing connections for the same session, so reconnections can accumulate and multiply updates.
- RealtimeV2 transport cleanup used `task?.cancel()` without a close code, and the receive loop did not guard against stale connection tokens, so a slow/failed close could keep old sockets delivering updates.
- Recent realtime commits (Jan 1–18) focused on reconnect coalescing/backoff/foreground behavior but did not add stale socket guards or explicit close semantics.

# Progress
- Traced update/notification paths in client and realtime/sync pipeline.
- Identified server fanout and client-side lack of dedupe as the multiplier points.
- Added debug toggles/logging for server connection fanout and update delivery.
- Added client-side duplicate detection logging and sync apply source summaries (direct vs bucket).
- Debug logging is now always-on (no flags): server logs when a user has >1 active connection or when fanout includes `newMessage`/`newMessageNotification`; client logs duplicate `newMessage` applies and direct vs bucket message update application.
- Observed active connections count reaching 7 for a user; confirmed all were for the same session (drops to zero on app quit).
- Updated RealtimeV2 transport cleanup to send an explicit close and added a connection token guard in the receive loop to ignore stale sockets.
- Removed temporary debug logging/helpers from server API and client.
