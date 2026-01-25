# RealtimeV2 Connection Manager Refactor Plan (2026-01-25)

## Goals
- Centralize connection lifecycle and reconnection logic in a single `ConnectionManager` actor.
- Connect immediately on login (no extra auth gate), while still handling token refresh safely.
- Structured concurrency throughout (no unscoped detached tasks in core flow).
- Shared iOS/macOS core logic with thin platform adapters.
- Clear state machine + diagnostics for debugging.
- Deterministic tests (manual clock + fake transport/session).

## High-Level Steps
1. Introduce connection core types (state, reason, constraints, snapshot, event, policy, clock).
2. Implement `ConnectionManager` actor with single event loop and session-scoped tasks.
3. Add platform event adapters (auth, lifecycle, network) feeding the manager.
4. Refactor protocol handling into `ProtocolSession` (no reconnect/backoff).
5. Simplify `WebSocketTransport` into a dumb transport (no reconnection, watchdog, path monitor).
6. Add `ConnectionHealthMonitor` owned by manager (ping/pong -> timeout events).
7. Wire `RealtimeV2` to `ConnectionManager` and `ProtocolSession`.
8. Add tests for reconnection, background/foreground, network up/down, auth failure, and immediate login connect.

## Detailed Task List
- [x] Add connection core types under `apple/InlineKit/Sources/RealtimeV2/Connection/`.
- [x] Implement `ConnectionManager` skeleton + event loop + snapshot stream.
- [x] Implement lifecycle/network/auth adapters.
- [x] Extract `ProtocolSession` from `ProtocolClient` (events, handshake, rpc, pong).
- [x] Update `TransportEvent` + simplify `WebSocketTransport`.
- [x] Add `ConnectionHealthMonitor` (manager-owned, session-scoped).
- [x] Update `RealtimeV2` to use manager/session, migrate state publishing.
- [x] Update or replace tests (foreground reconnect, new manager tests).

## Progress Log
- 2026-01-25: Plan created.
- 2026-01-25: Core types, ConnectionManager, adapters, ProtocolSession, transport simplification, wiring, and tests updated.

## Implementation Summary (What Changed + Why)
- **ConnectionManager actor** now owns connection lifecycle with a clear state machine, backoff, timeouts, ping loop, background grace, and constraint gating. This centralizes reconnection logic and makes behavior deterministic and testable.
- **ProtocolSession** extracted from the old client; it now focuses on protocol messages, handshake, RPC lifecycle, and emitting typed session events. It no longer manages reconnect/backoff.
- **Transport layer simplified** (`WebSocketTransport` + `TransportEvent`) into a dumb, single-connection transport without reconnection logic or path monitoring. ConnectionManager drives reconnects instead.
- **Adapters for auth/lifecycle/network** provide platform signals to the manager (Auth events, app active/background, NWPathMonitor).
- **RealtimeV2 wiring updated** to:
  - start ProtocolSession + ConnectionManager early,
  - connect immediately when credentials are present,
  - map manager snapshots to `RealtimeConnectionState`,
  - forward session events into sync + transactions.
- **Connection state broadcasting** changed to a multi-consumer `AsyncStream` per subscriber to avoid the single-consumer `AsyncChannel` bug where additional listeners could steal updates.
- **Connect-timeout fix**: now stops the transport before backing off to avoid “ghost” connections after timeout.
- **Event sending cleanup** in WebSocketTransport: removed extra `Task { await send(...) }` wrappers to avoid unbounded task creation while preserving backpressure guarantees of AsyncChannel.
- **Tests**:
  - Updated connection-manager tests to avoid timing races.
  - Added an integration test verifying Auth → RealtimeV2 coordination (login triggers connection init).
- **Deprecated `PingPongService`** (replaced by ConnectionManager-managed ping loop) to avoid accidental usage drift.

## What to Watch For
- **Backpressure vs. consumers**: Transport events are delivered via `AsyncChannel` with backpressure. If ProtocolSession isn’t started, transport event sends can suspend. RealtimeV2 start sequence currently ensures this is started first.
- **Connection state subscribers**: Each subscriber gets its own AsyncStream continuation; subscribers should cancel when done to avoid holding stale continuations.
- **Handshake/token availability**: If Auth reports “logged in” but token is temporarily unavailable, the handshake will fail and backoff. This is expected; verify logs if users appear “stuck” connecting.
- **Background behavior**: The manager allows a short grace period; extended background will suspend and stop transport. Confirm policy values against app needs.
- **Late transport opens**: The connect-timeout path now stops transport; if you see double-connects or delayed opens, check for any external calls to `transport.start()` bypassing the manager.
