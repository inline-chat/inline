# iOS Realtime V2 Connect Delay Findings (2026-01-07)

## Summary
Users report a 5–10s delay before iOS reconnects/refetches when opening the app in the morning. Review of Realtime V2 transport/client shows multiple places where reconnection is deferred until ping/timeout or socket error, especially after background/overnight idle and network transitions.

## Primary Likely Causes
1) Foreground transition does not probe/reconnect if client state is `.open`.
- `ProtocolClient.handleForegroundTransition` returns early when `state == .open`, so a stale socket is not verified on foreground. The next ping loop can be 10–25s later.
- Files:
  - `apple/InlineKit/Sources/RealtimeV2/Client/Client.swift` (handleForegroundTransition)
  - `apple/InlineKit/Sources/RealtimeV2/Client/PingPongService.swift` (ping interval)

2) No reachability monitoring in V2 transport.
- V2 `WebSocketTransport` has no NWPathMonitor, so a network change only causes reconnect after a socket error + backoff delay.
- Legacy transport handles network changes immediately and calls `ensureConnected()` on path satisfied.
- Files:
  - V2: `apple/InlineKit/Sources/RealtimeV2/Transport/WebSocketTransport.swift`
  - Legacy: `apple/InlineKit/Sources/InlineKit/RealtimeAPI/WebSocketTransport.swift` (NWPathMonitor handling)

3) Auth token hydration race on cold/locked start.
- `RealtimeV2` starts when `Auth.isLoggedIn` is true (based on userId), but `sendConnectionInit` fails when token is still nil. This can trigger a backoff until auth refresh completes.
- Files:
  - `apple/InlineKit/Sources/RealtimeV2/Realtime/Realtime.swift` (start if isLoggedIn)
  - `apple/InlineKit/Sources/RealtimeV2/Client/Client.swift` (sendConnectionInit)
  - `apple/InlineKit/Sources/Auth/Auth.swift` (token hydration flow)

4) V2 transport uses default URLSessionConfiguration.
- Legacy config explicitly sets `waitsForConnectivity = false`, `.responsiveData`, etc. V2 uses default configuration which may add system-level delays.
- Files:
  - V2: `apple/InlineKit/Sources/RealtimeV2/Transport/WebSocketTransport.swift` (session config)
  - Legacy: `apple/InlineKit/Sources/InlineKit/RealtimeAPI/WebSocketTransport.swift`

## Suggested Fixes (Highest impact first)
1) Foreground fast-probe even when state is `.open`.
- On `didBecomeActive`, send a fast ping or force reconnect if no pong within a short timeout.
- Remove early return in `handleForegroundTransition` that skips work when `.open`.

2) Add NWPathMonitor to V2 transport.
- When path is satisfied, immediately call `reconnect(skipDelay: true)` or open connection directly.
- When path becomes unsatisfied, transition to connecting/disconnected and cancel tasks.

3) Gate transport start on token presence / hydration.
- If token is nil but userId exists, delay start until `Auth.didHydrateCredentials == true` and token present.
- On token refresh, force immediate reconnect.

4) Align URLSessionConfiguration with legacy transport.
- Set `waitsForConnectivity = false`, `networkServiceType = .responsiveData`, etc.

## Quick Instrumentation Points (to confirm in logs)
- Foreground event → transport open → connectionOpen → sync fetch timings.
- Log when `handleForegroundTransition` is invoked and whether it triggers a reconnect.
- Log when `sendConnectionInit` fails due to missing token.

## Notes
- This is a review-only finding; no code changes applied.
