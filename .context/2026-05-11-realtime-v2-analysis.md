# Realtime V2 Internals Analysis

Analysis goal: map the Realtime V2 module internals, especially connection, reconnection, updates, catch-up, transport, and app wiring, and identify bugs that can leave the engine stuck in `connecting`, fail to update/sync correctly, or stop continuous reconnect attempts.

This document is a living artifact for the investigation. It intentionally describes code behavior only; no code changes are proposed here as implementation.

## Scope

Primary module:

- `Realtime/Realtime.swift`
- `Realtime/RealtimeState.swift`
- `Connection/ConnectionManager.swift`
- `Connection/ConnectionAdapters.swift`
- `Connection/ConnectionPolicy.swift`
- `Transport/WebSocketTransport.swift`
- `Transport/Transport.swift`
- `Client/Client.swift`
- `Client/ProtocolSessionTypes.swift`
- `Sync/Sync.swift`
- `Sync/SyncStorage.swift`
- `Transaction/Transactions.swift`

Production wiring:

- `InlineKit/Api.swift` constructs the singleton `Api.realtime`.

Adjacent production wiring that still matters:

- `InlineKit/RealtimeHelpers/RealtimeWrapper.swift` constructs `Realtime.shared`, which owns the legacy `RealtimeAPI`.
- `InlineIOS/InlineApp.swift` injects `Realtime.shared` into `EnvironmentValues.realtime`.
- `InlineMac/App/AppDependencies.swift` stores both `Realtime.shared` and `Api.realtime`, then injects both `.realtime` and `.realtimeV2`.
- `InlineKit/Utils/Env.swift` defaults `.realtime` to `Realtime.shared` and `.realtimeV2` to `Api.realtime`.
- Some UI still reads legacy `RealtimeAPIState`, especially `InlineMac/Views/Components/ConnectionStateConfiguration.swift`.
- Some legacy transaction helpers still invoke `Realtime.shared.invoke`, while most newer paths call `Api.realtime`.

This means production can still run two websocket/protocol engines: legacy `RealtimeAPI` and V2 `RealtimeV2`. V2 owns update processing, but legacy still connects, authenticates, publishes connection state, and leaves Sentry breadcrumbs.

Relevant tests:

- `Tests/InlineKitTests/RealtimeV2/AuthRealtimeIntegrationTests.swift`
- `Tests/InlineKitTests/RealtimeV2/ForegroundReconnectTests.swift`
- `Tests/InlineKitTests/RealtimeV2/NewTransactionsTests.swift`
- `Tests/InlineKitTests/RealtimeV2/RealtimeSendTests.swift`
- `Tests/InlineKitTests/RealtimeV2/RealtimeStateDisplayTests.swift`
- `Tests/InlineKitTests/RealtimeV2/SyncTests.swift`

## High-Level Architecture

`RealtimeV2` is the root actor. It owns:

- `ProtocolSession`, which translates transport events into protocol/session events and sends connection init, RPC, and ping messages.
- `ConnectionManager`, which owns the connection state machine, constraints, retry/backoff, auth/connect/ping timeouts, foreground/background handling, and wake probes.
- `Sync`, which applies realtime update payloads and fetches missed updates per bucket.
- `Transactions`, which queues RPC-backed transactions and requeues or fails them on connection loss.
- `RealtimeState`, which exposes a Combine/SwiftUI-friendly display state.

The production singleton in `InlineKit/Api.swift` wires:

- `WebSocketTransport2()` (`WebSocketTransport` via compatibility alias)
- `Auth.shared.handle`
- `InlineApplyUpdates()`
- `GRDBSyncStorage()`
- `DefaultTransactionPersistenceHandler()`
- `ChatTransactionBlockerResolver()`

## Module Map

### Root

- `Realtime/Realtime.swift`: root actor, public API, startup wiring, connection/session/transaction listeners, state mapping, transaction send loop, auth-recovery handling.
- `Realtime/RealtimeState.swift`: UI-facing display state and snapshot publisher.

### Connection

- `Connection/ConnectionManager.swift`: state machine for constraints, connect, auth handshake, backoff, ping, foreground/background, and wake probes.
- `Connection/ConnectionAdapters.swift`: bridges auth, app lifecycle, and network monitor signals into `ConnectionManager`.
- `Connection/ConnectionPolicy.swift`: backoff and timeout values.

### Transport

- `Transport/Transport.swift`: transport protocol and event definitions.
- `Transport/WebSocketTransport.swift`: URLSession websocket implementation. It only connects, sends, receives, and reports disconnects; it does not retry.

### Protocol Session

- `Client/Client.swift`: `ProtocolSession`, which converts transport events into protocol events, sends `connectionInit`, RPC calls, pings, and cancels pending RPC continuations on reset.
- `Client/ProtocolSessionTypes.swift`: session event and error types.

### Sync

- `Sync/Sync.swift`: realtime update routing, bucket sequencing, catch-up fetches, global update-state fetch, and sync activity state.
- `Sync/SyncStorage.swift`: bucket/global sync state protocol and key model.
- `Sync/GRDBSyncStorage.swift`: persisted `sync_bucket_state` and `sync_global_state` implementation.

### Transactions

- `Transaction/Transactions.swift`: queued, in-flight, acked, completed, and persisted transaction state.
- `Transaction/TransactionPersistenceHandler.swift`: persistence protocol and default transaction persistence.
- `Transaction/TransactionBlockerResolver.swift`: optional transaction blocker resolution.

## Connection State Mapping

Internal connection states live in `ConnectionState`:

- `stopped`
- `waitingForConstraints`
- `connectingTransport`
- `authenticating`
- `open`
- `backoff`
- `backgroundSuspended`

Public/UI states live in `RealtimeConnectionState`:

- `connecting`
- `updating`
- `connected`

`RealtimeV2.mapConnectionState(_:)` maps only `open` to `.connected`; every other internal state maps to `.connecting`. `RealtimeV2` then overlays `.updating` when the transport is `.connected` and `Sync` reports active catch-up work.

This means public `.connecting` is broad: it can mean waiting for auth, no network, background suspension, active transport connect, handshake, or retry backoff. Any user-visible "stuck connecting" report needs an internal `ConnectionSnapshot` to tell those apart.

## Startup And Wiring Flow

1. `Api.realtime` constructs `RealtimeV2`.
2. `RealtimeV2.init` creates `ProtocolSession`, `ConnectionManager`, `Sync`, `Transactions`, `RealtimeState`, and the auth/lifecycle/network adapters.
3. `RealtimeV2.init` launches `Task { await self.start() }`.
4. `RealtimeV2.start`:
   - installs the sync activity listener,
   - starts `RealtimeState`,
   - starts snapshot/session/transaction listeners,
   - starts `ProtocolSession`,
   - starts `ConnectionManager`,
   - starts the auth adapter,
   - if a token exists, marks auth available and calls `connectNow`.
5. `ConnectionManager.start` starts its event/session loops and yields `.start`.
6. `.start` evaluates constraints. If auth, network, app-active, and user-wants-connection are satisfied, it starts connecting.
7. `startConnecting` increments `sessionID`, cancels timers, transitions to `connectingTransport`, calls `session.startTransport()`, and starts a connect timeout.
8. `ProtocolSession.startTransport` calls `transport.start()`.
9. `WebSocketTransport.start` emits `.connecting`, opens the URLSession websocket, and later emits `.connected` from the delegate `didOpen`.
10. `ConnectionManager` receives `.transportConnected`, transitions to `authenticating`, starts auth timeout, and calls `session.startHandshake()`.
11. `ProtocolSession.startHandshake` sends `connectionInit`.
12. Server `connectionOpen` becomes `.protocolOpen`; `ConnectionManager` transitions to `open`, cancels auth timeout, resets attempt count, and starts ping loop.

## Reconnect Flow

The transport itself does not retry. It emits `.disconnected(errorDescription:)` and returns to `idle`.

`ConnectionManager` handles retry:

1. Any transport disconnect while in `connectingTransport`, `authenticating`, or `open` calls `handleTransportDisconnect`.
2. If constraints are no longer satisfied, manager transitions to `waitingForConstraints` and stops the transport.
3. Otherwise it increments `attempt`, transitions to `backoff`, and schedules `backoffFired`.
4. On `backoffFired`, constraints are evaluated again.
5. If still satisfied, `startConnecting` starts a fresh transport and connect timeout.

Backoff policy:

- attempts below 8 use `min(8.0, 0.2 + pow(attempt, 1.5) * 0.4)` seconds.
- attempts 8 and above use 8 seconds plus 0-5 seconds jitter.

The retry path is intended to continue indefinitely while constraints remain satisfied.

## Connection Manager State Machine

### Inputs

External signals enter as `ConnectionEvent`:

- lifecycle: `.start`, `.stop`, `.appForeground`, `.appBackground`, `.systemWake`, `.backgroundGraceExpired`
- explicit connect: `.connectNow`
- auth: `.authAvailable`, `.authLost`
- network: `.networkAvailable`, `.networkUnavailable`
- transport: `.transportConnected`, `.transportDisconnected`
- protocol: `.protocolOpen`, `.protocolAuthFailed`
- health: `.pingTimeout`, `.backoffFired`

### State behavior

| State | Meaning | Main exits |
| --- | --- | --- |
| `stopped` | Manager is not trying to connect. | `.start`, `.connectNow`, `.authAvailable` evaluate constraints. |
| `waitingForConstraints` | At least one required constraint is missing. | Auth/network/app/user constraints becoming satisfied starts connect. |
| `connectingTransport` | Transport `start()` has been called and connect timeout is running. | transport connected -> `authenticating`; timeout/disconnect -> backoff or constraints. |
| `authenticating` | Websocket is open and `connectionInit` was sent. Auth timeout is running. | protocol open -> `open`; auth lost/auth failed -> constraints; disconnect/timeout -> backoff. |
| `open` | Protocol handshake completed. Ping loop runs. | transport disconnect/ping timeout/auth lost/background -> backoff or constraints. |
| `backoff` | Retry timer is active. | timer fires -> evaluate constraints; connect/auth/network events can reset attempt and reconnect. |
| `backgroundSuspended` | Connection intentionally stopped for background. | foreground/system wake evaluates constraints. |

### Constraint model

Connect is allowed only when all effective constraints are satisfied:

- user wants connection
- auth is available
- network is available
- app is active enough for the current platform policy

When constraints are missing, the manager stops transport and waits. When constraints are present and transport disconnects, it schedules another attempt. Therefore, continuous retry depends on remaining in the "constraints satisfied" branch.

### Timers

- connect timeout: active in `connectingTransport`; stops transport and treats it as disconnect.
- auth timeout: active in `authenticating`; stops transport and treats it as disconnect.
- ping timeout: active after a sent ping in `open`; stops transport and moves to retry.
- backoff timer: active in `backoff`; fires another constraint evaluation.
- background timeout: suspends/stops transport after background policy allows it.

## Protocol Session Flow

`ProtocolSession` is the bridge between byte transport and protocol semantics:

1. `ConnectionManager` asks it to `startTransport()`.
2. Transport emits `.connected`.
3. Session emits `.transportConnected`.
4. Manager moves to `authenticating` and asks session to `startHandshake()`.
5. Session sends `connectionInit` using the current auth token.
6. Server replies with `connectionOpen`.
7. Session emits `.protocolOpen`.
8. Manager moves to `open`.

Important reset behavior:

- transport `.disconnected` calls `ProtocolSession.reset()`;
- reset fails pending RPC continuations and clears session state;
- the manager owns the next retry.

Important error behavior:

- if local auth is missing before sending `connectionInit`, session emits `.authFailed`;
- if sending handshake fails for another reason, session emits `.transportDisconnected("handshake_failed")`;
- if the server sends `connectionError`, session emits `.connectionError`, but `ConnectionManager` only forwards that event to listeners and does not immediately drive the state machine from it.

## Transport Layer

`Transport` exposes:

- `events: AsyncChannel<TransportEvent>`
- `start()`
- `stop()`
- `send(_:)`

`WebSocketTransport` states:

- `idle`
- `connecting`
- `connected`

Key behavior:

- `start()` only works from `idle`; it emits `.connecting` and opens a websocket.
- `stop()` cancels current task/receive loop and emits `.disconnected(errorDescription: "stopped")`.
- `send(_:)` requires internal state `.connected`.
- `didOpen` starts the receive loop and emits `.connected`.
- receive-loop errors, delegate close, or task completion errors call `handleDisconnect`, which cleans up and emits `.disconnected`.

The transport has no built-in reconnect/backoff. That is deliberate: `ConnectionManager` owns retry.

## Sync Flow

### Incoming realtime updates

`RealtimeV2.listenToSessionEvents` sends `ProtocolSessionEvent.updates` to `Sync.process(updates:)`.

`Sync.process` then routes each update:

- `chatHasNewUpdates`: notify the chat bucket actor and maybe fetch.
- `spaceHasNewUpdates`: notify the space bucket actor and maybe fetch.
- sequenced update with a known `BucketKey`: send to that bucket actor for ordering/gap handling.
- unsequenced or unkeyed update: apply directly via `UpdatesEngine` and update global sync date.

Direct application still updates bucket state for any direct updates that can be keyed. This keeps bucket sequence from lagging after simple in-order realtime updates.

### Connection-open catch-up

When public state becomes `.connected`, `Sync.connectionStateChanged(.connected)` runs:

1. `fetchUserBucket()` catches up the user bucket.
2. `getStateFromServer()` calls `getUpdatesState` using persisted global last sync date.
3. Server replies with `chatHasNewUpdates` and `spaceHasNewUpdates` hints.
4. Those hints trigger bucket fetches.
5. Bucket fetches call `getUpdates` until final or caught up.

If global last sync date is zero, the client seeds it to five days ago. If it is older than fourteen days, the client resets it to now instead of clearing and refetching everything.

### Bucket sequencing

Each `BucketActor` owns one bucket's sequence state:

- current bucket seq/date
- buffered realtime updates that arrived ahead of local seq
- pending fetch bounds from `hasNewUpdates`
- active fetch flag
- retry task

Realtime sequenced updates:

- `seq <= current`: ignored as stale.
- `seq == current + 1`: applied immediately, then buffered contiguous updates are drained.
- `seq > current + 1`: buffered and fetch is triggered to fill the gap.

Fetch results:

- `resultType == TOO_LONG`: cold start fast-forwards; warm state may slice and continue.
- non-progress response returns failure and schedules retry.
- server seq behind local clears buffered updates and treats the fetch as done.
- normal updates are applied in order and bucket state advances.

Bucket fetch retry is indefinite when `fetchNewUpdatesOnce` returns `false`, using increasing delay capped at 30 seconds. It does not protect against an RPC that stays pending forever.

### Bucket key mapping

The client maps many update types to buckets:

- chat bucket examples: new/edit/delete message, reactions, pinned message, chat metadata, participants, chat visibility.
- space bucket examples: space member add/delete/update.
- user bucket examples: dialog notification settings, dialog archive state, read max id, user settings, user status, joined space membership.

Known unkeyed or skipped update types that matter for this audit:

- `chatOpen` is produced by server user-bucket catch-up and applied by `UpdatesEngine`, but is not included in `Sync.shouldProcessUpdate` and is not mapped in `getBucketKey`.
- `messageActionInvoked` and `messageActionAnswered` are produced by server user-bucket catch-up. `messageActionAnswered` is applied by `UpdatesEngine`; `messageActionInvoked` is not currently handled by `UpdatesEngine`.
- `newMessageNotification`, `updateMessageID`, `updateComposeAction`, and `chatSkipPts` are unkeyed or intentionally skipped paths that need intent confirmation.

## Transactions Flow

`RealtimeV2.send` and typed transaction helpers enqueue `TransactionRecord` values in `Transactions`.

Queue processing:

1. `Transactions.dequeue()` chooses the next runnable transaction.
2. `RealtimeV2.runTransaction` maps it to an RPC and sends it through `ProtocolSession`.
3. A successful RPC result completes the transaction.
4. A protocol ACK moves it to "sent" and deletes persistence.
5. Connection loss clears RPC maps.
6. On next `open`, `restartTransactions()` requeues in-flight transactions and fails acked non-retry transactions.

Important behavior:

- Queue draining only happens when public realtime state is `.connected` or `.updating`.
- Send failures are caught, the transaction is requeued, and the queue is signaled again.
- There is a FIXME in this failure path asking whether the connection should be restarted.

## Server Contract For Catch-Up

Relevant server flow:

- realtime `connectionInit` errors send `connectionError` or close the websocket;
- `updates.getUpdatesState` returns bucket hints for chats/spaces changed since a date;
- `updates.getUpdates` returns bucket updates from a starting seq, capped by total limits;
- user bucket conversion can inflate `chatOpen`, `messageActionInvoked`, and `messageActionAnswered`;
- `RealtimeUpdates.pushToUser` is used for direct user update delivery and persisted user-bucket updates.

This means client catch-up correctness depends on the Swift `Sync` module being able to process every persisted update type that server can replay for a bucket. Direct realtime delivery alone is not enough for users who were offline or disconnected.

## Test Coverage Map

Covered:

- login starts transport;
- transport connect drives handshake;
- auth failure disables auth and waits for auth recovery;
- auth recovery restarts connection;
- ping timeout triggers retry/backoff;
- transaction queue drains after reconnect;
- acked non-retry transactions fail after reconnect;
- sequenced sync gaps trigger bucket catch-up;
- out-of-order realtime updates are buffered and drained;
- non-progress bucket fetch does not busy-loop;
- getUpdatesState advances global date;
- user bucket fetch runs on connect;
- fetch limiter bounds concurrent bucket fetches.

Not covered or only lightly covered:

- connect timeout continuously retries;
- auth timeout continuously retries;
- server `connectionError` with a non-empty but invalid token;
- repeated caller `connectIfNeeded` during retry backoff;
- failed `getUpdatesState` retry while connection remains open;
- hung `getUpdatesState` or `getUpdates` RPC while transport remains open;
- user-bucket catch-up for `chatOpen`, `messageActionInvoked`, and `messageActionAnswered`;
- transaction send failure while public state remains `.connected`;
- macOS lifecycle background/foreground edge cases.

## Sentry Evidence From 2026-05-04

Commands used:

- `sentry issues usenoor/inline-ios-macos --query "RealtimeV2" --limit 20 --json`
- `sentry issue view <issue-id> --json`
- targeted searches for `"failed to get updates state"` and `"failed to fetch updates"`

Observed issue groups:

| Issue | Title | Count / users | Why it matters |
| --- | --- | --- | --- |
| `INLINE-IOS-MACOS-187` / `6837447707` | `RealtimeV2.TransactionError: timeout` | about 768 filtered / 16 users | V2 transactions time out in production. Breadcrumbs on the sampled event include legacy realtime websocket startup, not V2 transport breadcrumbs. |
| `INLINE-IOS-MACOS-1FC` / `6995211209` | `RealtimeV2.TransactionError: invalid` | about 327 filtered / 17 users | Sampled event shows repeated legacy websocket connects while `NWPath` is unsatisfied. |
| `INLINE-IOS-MACOS-17W` / `6835257802` | `RealtimeV2.TransactionError: rpcError` | 3501 / 19 users | Broad V2 transaction failures exist; not enough by itself to prove connection-loop behavior. |
| `INLINE-IOS-MACOS-1T3` / `7248530145` | `RealtimeV2.ProtocolSessionError: notConnected` | 135 / 6 users | V2 transaction send fails at `RealtimeV2/Realtime.swift:244` around disconnect. Trace also includes catch-up failures. |
| `INLINE-IOS-MACOS-1RS` / `7224191795` | `failed to get updates state: stopped` | 4 / 2 users | Global catch-up can fail right after a connection state says connected. No same-open retry exists. |
| `INLINE-IOS-MACOS-23K` / `7457763606` | `failed to fetch updates for bucket user: notConnected` | 5 / 1 user | User-bucket catch-up repeatedly fails because the protocol session is not connected. |
| `INLINE-IOS-MACOS-23J` / `7457763603` | `failed to fetch updates for bucket user: stopped` | 1 / 1 user | Same user-bucket catch-up path fails because pending RPCs were reset. |
| `INLINE-IOS-MACOS-1XX` / `7335786512` | `WebSocket task completed with HTTP status 101` | 28672 / 10 users | Legacy transport is still producing a very large volume of websocket completion/timeout events. |
| `INLINE-IOS-MACOS-21E` / `7405515096` | `InlineKit.TransportError: connectionTimeout` | 1660 / 14 users | Legacy transport connection timeouts are common and appear in traces near V2 catch-up failures. |
| `INLINE-IOS-MACOS-16T` / `6824088309` | `Failed to send ping: notConnected` | 6 / 2 users | V2 ping send can discover a dead transport but only logs; reconnect waits for the later ping timeout. |

High-signal event details:

- `6995211209` sampled event shows `network_available=false`, `nw_path_status=unsatisfied`, `NSURLErrorDomain -1009`, and immediate legacy reconnect scheduling with `delay_s=0.1`. That maps directly to `RealtimeAPI/WebSocketTransport.shouldRetryImmediately` treating `NSURLErrorNotConnectedToInternet` as immediate retry and `attemptReconnection` not checking `networkAvailable`.
- `7248530145` sampled event shows old transport disconnect breadcrumbs, then V2 `ProtocolSessionError.notConnected` from transaction send. The same trace includes `failed to get updates state: stopped` and `failed to fetch updates for bucket user: stopped`.
- `7457763606`, `7457763603`, and `7224191795` sampled events are all macOS build 3902 and share a trace with `connectionTimeout`, `NSPOSIXErrorDomain Code=57` socket-not-connected, `NSPOSIXErrorDomain Code=54` connection-reset, and ping/send failures. This is a session-health cluster, not only a skipped-update mapping bug.
- V2 transport logs are not currently present as Sentry breadcrumbs in the sampled events. The realtime breadcrumbs found in V2 issues are from legacy `RealtimeAPI/WebSocketTransport`.

## Symptom-To-Cause Map

### Too many "connecting" indicators

Likely paths:

- Legacy realtime is still started and still publishes `RealtimeAPIState`.
- Legacy transport retries every 0.1 seconds for `NSURLErrorNotConnectedToInternet`.
- Foreground transitions reset legacy reconnection attempts and directly call `connect()`.
- V2 `connectNow`, auth available, network available, app foreground, and system wake also reset V2 attempt counters and cancel backoff.
- Public V2 `.connecting` collapses `backoff`, `waitingForConstraints`, `backgroundSuspended`, `connectingTransport`, `authenticating`, and `stopped` into one label.

### Stuck in "connecting" until restart

Likely paths:

- Server `connectionError` during handshake is forwarded to listeners but not treated as a state-machine input unless local auth is missing.
- Non-empty invalid auth can repeatedly hit auth timeout/backoff and stay public `.connecting`.
- Legacy UI can remain in `connecting` from `Realtime.shared` even if V2 is healthy.
- V2 can sit in `waitingForConstraints` forever for auth/network/app-active/user-wants, but public state has no reason field.
- V2 network starts optimistic (`networkAvailable` defaults true) until `NWPathMonitor` reports, so first offline launch can briefly attempt a connect before constraints are corrected.

### Missed updates or missed catch-up until refetch

Likely paths:

- `getUpdatesState` is one-shot per `.connected` transition and has no same-open retry after failure.
- User-bucket fetch retries exist, but can repeatedly fail with `stopped` or `notConnected` during unstable sessions.
- `getUpdatesState` and `getUpdates` use `timeout: nil`, so a server-side no-response can leave catch-up pending until transport reset.
- V2 ping send failure is logged but not surfaced to `ConnectionManager` immediately. The manager can remain internally `open` until the ping timeout fires.
- Catch-up filtering skips some persisted user-bucket updates while still committing the returned bucket seq.
- Cold-start `TOO_LONG` can intentionally fast-forward and discard old bucket payloads.

## Findings And Bug Candidates

### A. Legacy realtime still runs beside V2 and can explain "too many connectings"

Evidence:

- `Realtime.shared` owns legacy `RealtimeAPI` and starts when auth is logged in.
- iOS and macOS inject both `.realtime` and `.realtimeV2`.
- `ConnectionStateProvider` still reads legacy `RealtimeAPIState`.
- Legacy `RealtimeAPI` no longer applies server update payloads, but still connects, authenticates, retries, publishes state, and records Sentry breadcrumbs.
- V2 Sentry issues contain legacy realtime breadcrumbs.

Likely impact:

- Users can see legacy "connecting..." even when V2 is connected.
- The app can maintain two websocket connections to the same realtime endpoint.
- Legacy retry noise can look like V2 instability in Sentry because it is attached to V2 error events as breadcrumbs.

Confidence: high.

### B. Legacy transport reconnects aggressively while the network is unavailable

Evidence:

- Legacy `WebSocketTransport.connect()` does not guard `networkAvailable`.
- `shouldRetryImmediately(error:)` returns true for `NSURLErrorNetworkConnectionLost` and `NSURLErrorNotConnectedToInternet`.
- `attemptReconnection(immediate:)` schedules 0.1 second reconnects without checking `networkAvailable`.
- `setNetworkAvailable(false)` only notifies state. It does not cancel an active connection or scheduled reconnect.
- Sentry issue `6995211209` confirms repeated connect attempts while `NWPath` is unsatisfied.

Likely impact:

- Excess connection attempts while offline.
- Repeated user-visible connecting state from legacy UI.
- Battery/network churn and noisy Sentry breadcrumbs.

Confidence: high.

### C. V2 catch-up has a real disconnect race, confirmed by Sentry

Evidence:

- On `.connected`, `Sync.connectionStateChanged` immediately calls `fetchUserBucket()` and `getStateFromServer()`.
- Both send RPCs through `ProtocolSession.callRpc`.
- `ProtocolSession.reset()` fails pending RPCs with `.stopped` on transport disconnect.
- `ProtocolSession.callRpc` fails immediately with `.notConnected` when transport send races with disconnect.
- `getStateFromServer()` catches and logs the error, then returns with no retry while the connection remains open.
- Bucket fetch retries after failures, but a burst of `notConnected` errors can still leave the user stale until a later successful retry or refetch.
- Sentry issues `7224191795`, `7457763606`, and `7457763603` confirm `stopped` and `notConnected` in these exact catch-up paths.

Likely impact:

- A reconnect can appear successful while the catch-up that should repair missed updates fails.
- Chat/space hints may be missed until another reconnect or explicit refetch.
- User-bucket updates can remain stale during unstable network windows.

Confidence: high.

### D. V2 transaction send can requeue against a dead session without forcing reconnect

Evidence:

- `RealtimeV2.runTransaction` sends via `ProtocolSession.sendRpc`.
- If send throws, it logs, requeues, and signals the transaction queue.
- The failure path has a FIXME about restarting the connection.
- Sentry issue `7248530145` confirms `ProtocolSessionError.notConnected` at this exact path.

Likely impact:

- Transactions can churn while the public state is still `.connected` or `.updating`.
- The queue does not itself mark the session unhealthy or ask `ConnectionManager` to reconnect.
- Users can see operations fail or delay until another connection-state transition happens.

Confidence: high.

### E. V2 ping send failure leaves a temporary false-open window

Evidence:

- `ConnectionManager.startPingLoop` calls `sendPingIfNeeded`.
- `sendPingIfNeeded` sets `pendingPingNonce`, calls `session.sendPing`, then schedules a ping timeout.
- `ProtocolSession.sendPing` catches transport send errors and only logs `Failed to send ping: ...`.
- It does not emit a session event or throw back to `ConnectionManager`.
- Sentry issue `6824088309` confirms `Failed to send ping: notConnected`.

Likely impact:

- The manager can remain internal `.open` for up to the ping timeout even though transport send already proved not connected.
- During that window, transactions and sync RPCs can attempt sends and hit `notConnected`.
- This lines up with the catch-up failure trace containing both ping-send failure and `getUpdates`/transaction `notConnected`.

Confidence: medium-high.

### F. Legacy macOS connection-state UI has a stale hide-task race

Evidence:

- `ConnectionStateProvider` schedules a one-second hide task when it receives `.connected`.
- The delayed task checks the captured `nextApiState == .connected`, not the current `apiState`.
- If the legacy state changes back to `.connecting` before the delay fires, the old task can still set `shouldShow = false`.
- V2 `RealtimeState` avoids this by checking current `connectionState == .connected` before hiding.

Likely impact:

- Legacy macOS UI can hide a real connecting state after a recent connected transition.
- This can make connection indicators look inconsistent across old and new UI surfaces.

Confidence: medium.

### 1. Server `connectionError` can leave non-empty invalid auth retrying forever as `.connecting`

Evidence:

- Server sends `connectionError` when `connectionInit` handling fails.
- `ProtocolSession` emits `.connectionError`.
- `ConnectionManager` forwards `.connectionError` to listeners but does not immediately stop transport, mark auth lost, or enter backoff from that event.
- `RealtimeV2.handleConnectionErrorDuringHandshake` refreshes auth from storage and only marks auth unavailable when auth is `.reauthRequired` or the authenticated token is empty.

Likely impact:

- A revoked/expired/non-empty token can loop through auth timeout and backoff forever.
- Public state remains `.connecting`; there is no clear auth-required state for UI.
- The reconnect loop is technically continuous, but it cannot recover without auth state changing, and the user may never be prompted.

Confidence: high.

### 2. Protocol `connectionError` is not a state-machine input

Evidence:

- `ConnectionManager.handleSessionEvent` handles `.authFailed`, `.transportConnected`, `.protocolOpen`, `.transportDisconnected`, and `.pong`.
- `.connectionError` falls through to listener forwarding only.
- There is a `.protocolAuthFailed` event in the state machine, but real server `connectionError` does not feed it.

Likely impact:

- Handshake errors wait for auth timeout or transport close instead of being handled immediately.
- Retry/backoff reason and metrics become less precise.
- Combined with finding 1, invalid-auth failure can look like a generic stuck connect.

Confidence: high.

### 3. Public `.connecting` hides retry/backoff/constraint causes

Evidence:

- `RealtimeV2.mapConnectionState(_:)` maps `backoff`, `waitingForConstraints`, `backgroundSuspended`, and `stopped` to public `.connecting`.

Likely impact:

- UI and callers cannot distinguish "actively retrying" from "will never retry until auth/network/app-active changes".
- This does not by itself break retries, but it can make a permanent `waitingForConstraints` state look like a stuck active connection attempt.

Confidence: high.

### 4. Transaction send failure can hot-loop without forcing reconnect

Evidence:

- `RealtimeV2.runTransaction` catches send/RPC errors, requeues the transaction, and signals the queue.
- Queue draining is allowed while public state is `.connected` or `.updating`.
- The failure path contains a FIXME asking whether the connection should be restarted.

Likely impact:

- If the public state still says connected but `ProtocolSession.callRpc` fails synchronously, the same transaction can be retried immediately.
- This can create CPU/log churn and starve useful work.
- It also may not heal a half-broken protocol session because no reconnect is forced from the send-failure path.

Confidence: medium-high.

### 5. `getUpdatesState` failure is logged but not retried while still connected

Evidence:

- `Sync.connectionStateChanged(.connected)` calls `getStateFromServer()`.
- `getStateFromServer()` catches and logs errors, then returns.
- There is no retry task for global update-state fetch; it relies on a future reconnect or future realtime hints.

Likely impact:

- If the one global catch-up call fails after reconnect, chat/space bucket hints may not be discovered.
- The user can remain connected but missing updates until another event or reconnect happens.

Confidence: high.

### 6. User-bucket catch-up can skip `chatOpen` and message action updates while advancing seq

Evidence:

- Server user-bucket conversion can produce `chatOpen`, `messageActionInvoked`, and `messageActionAnswered`.
- `UpdatesEngine` applies `chatOpen` and `messageActionAnswered`.
- `Sync.shouldProcessUpdate` does not include those update kinds.
- `getBucketKey` does not map `chatOpen`, so a sequenced realtime `chatOpen` is direct-applied without advancing user bucket state.
- `messageActionInvoked` is not handled by `UpdatesEngine`.

Likely impact:

- Offline catch-up can permanently skip user-bucket `chatOpen` or message action updates because bucket seq advances after fetch.
- Sidebar visibility/open-chat state can fail to sync after disconnect.
- Message action state may fail to sync or display inconsistently depending on which action update kind is involved.

Confidence: high for `chatOpen`, medium for message actions pending product intent.

### 7. Bucket fetch retry does not cover hung RPCs

Evidence:

- Bucket fetches call `client.callRpc(.getUpdates, timeout: nil)`.
- Global state fetch calls `client.callRpc(.getUpdatesState, timeout: nil)`.
- Bucket retry happens only when `fetchNewUpdatesOnce` returns false or throws.
- `ProtocolSession.reset()` should fail pending RPCs on transport disconnect, but if transport stays open and the server never replies, the call can remain pending.

Likely impact:

- A hung catch-up RPC can stall catch-up indefinitely.
- If sync activity is active, public state can remain `.updating` rather than `.connected`.
- Continuous reconnect does not help unless another health path closes the transport.

Confidence: medium.

### 8. `connectIfNeeded` can reset retry attempt/backoff timing

Evidence:

- `RealtimeV2.connectIfNeeded` sets auth available and calls `startTransport`.
- `startTransport` publishes `.connecting`, calls `connectionManager.start()`, then `connectNow()`.

Likely impact:

- If called while already open or connecting, `ConnectionManager.connectNow` sets `attempt = 0`, cancels backoff, and evaluates constraints. The state machine ignores it for `connectingTransport`, `authenticating`, and `open`, so it is mostly harmless.
- It can reset attempt/backoff state during retry windows, which may make reconnect behavior less predictable if callers repeatedly call `connectIfNeeded`.

Confidence: medium-low.

### 9. Cold-start `TOO_LONG` intentionally skips old bucket payloads

Evidence:

- On cold start, bucket fetch can fast-forward when server returns `TOO_LONG`.
- `SyncConfig.enableMessageUpdates` defaults to false.
- The code treats this as acceptable catch-up behavior rather than replaying all historical message updates.

Likely impact:

- This is probably intentional, but it can be mistaken for a sync bug if expected behavior is "replay every missed message mutation".
- It matters when diagnosing "missed updates" reports because not every skipped old update is a bug.

Confidence: medium.

## Likely Fix Order

1. Decide ownership between legacy realtime and V2.
   - Migrate remaining UI from `RealtimeAPIState` to V2 `RealtimeState`.
   - Stop starting legacy `RealtimeAPI` automatically if it is no longer needed for updates or RPCs.
   - If legacy RPC compatibility is still required, keep it explicit and remove its user-facing connection state.
2. Stop offline reconnect storms in legacy transport while it remains in production.
   - Gate `connect()` and scheduled reconnect firing on `networkAvailable`.
   - Do not treat `NSURLErrorNotConnectedToInternet` as a 0.1 second immediate retry while `NWPath` is unsatisfied.
   - Cancel or defer scheduled reconnects when the network becomes unavailable.
3. Make V2 session send failures mark the connection unhealthy.
   - Transaction `notConnected` and ping-send `notConnected` should force a reconnect or emit an event that `ConnectionManager` handles.
   - Avoid immediate transaction requeue loops while the same open session is already known bad.
4. Make catch-up robust inside one open session.
   - Add bounded retry for `getUpdatesState`.
   - Add RPC timeouts for `getUpdatesState` and `getUpdates`.
   - Ensure catch-up retries stop or pause cleanly while the session is not connected.
5. Close the update mapping gaps.
   - Decide durable behavior for `chatOpen`, `messageActionInvoked`, `messageActionAnswered`, notification updates, compose updates, and message id updates.
   - Do not advance bucket seq past updates that must be applied but were filtered out.
6. Improve observability before and after fixes.
   - Add V2 breadcrumbs/tags for internal state, reason, attempt, session id, network constraint, and app constraint.
   - Log/capture when V2 maps server `connectionError` to auth loss versus transient handshake failure.
   - Add a visible/debuggable connection reason so user-facing "connecting" is not a single opaque bucket.

## Open Questions To Continue

- Should legacy `Realtime.shared` be fully disabled or reduced to an RPC compatibility shim now that V2 owns updates?
- Should old UI state providers be migrated from `RealtimeAPIState` to V2 `RealtimeState` before diagnosing user-facing connection banners?
- Should legacy reconnect check `networkAvailable` before direct connect/reconnect, especially for immediate retry?
- Should server `connectionError` during handshake always be treated as auth loss, or should it split invalid-token, protocol-version, and transient server errors?
- Should public realtime state expose richer substate/reason for `connecting`?
- Should global `getUpdatesState` have bounded retry while the connection remains open?
- Which user-bucket updates are intended to be catch-up durable: `chatOpen`, message actions, notification updates, compose actions, and transient statuses?
- Should transaction send failure force a transport restart or mark the session unhealthy?
- Should ping send failure immediately force reconnect instead of waiting for ping timeout?
- Should `callRpc` used by Sync have a timeout independent of transport health?
