# RealtimeV2

The Apple realtime client: connection lifecycle, the protocol session, direct RPCs,
durable transactions and the sync engine. This file records the contracts that are easy to
break from the outside; the code comments carry the rest.

## Layers

| Owner | Role |
|---|---|
| `Transport/` | Bytes on a socket (legacy V2 WebSocket, V3 carrier, negotiation between them). Emits `TransportEvent`s; never knows about requests. |
| `Connection/ConnectionManager` | One serial command loop deciding when a transport should exist: constraints (auth, network, app state), backoff, handshake and ping timers, reconnect reasons, transition telemetry. |
| `Client/ProtocolSession` | One protocol session over the current transport: handshake, message IDs, inbound routing. Hosts the direct-RPC ledger adapter. |
| `Client/RequestLedger` | Pure (Sans-I/O) ownership of direct requests across connections. |
| `Transaction/` | Durable, optimistic application mutations with their own queue, replay policy and persistence. |
| `Sync/` | Bucketed catch-up and live update application with atomic cursor commits. |
| `Realtime/RealtimeV2` | The facade the app talks to. Wires the above together per account generation. |

## Direct RPC contract

`ProtocolSession.callRpc` (reached through `RealtimeV2.callRpcDirect`, `RealtimeDirectSession`
and the sync engine) follows MtProtoKit's request service: **a request outlives the connection
it was dispatched on.**

- A call made while no session is open waits for the next open session, bounded only by the
  caller's `timeout`. The transport being down is not a caller error.
- Until the session has reported its first open or loss, the ledger assumes a connection may
  exist and lets the transport decide; a `TransportError.notConnected` is the proof that there
  is none, after which nothing dispatches until `markOpen`. Owners that never report session
  edges (bare sessions in tests) therefore behave exactly as before.
- A read-only call (`inlineProtocolRpcMethodIsReadOnly`) whose reply was lost with a connection
  is re-sent on the next session under a fresh message ID. Callers see a slower reply.
- A write that may have reached the wire is never re-sent blind. It resolves as
  `commitOutcomeUnknown` and its owner reconciles. A write the transport refused before
  accepting bytes, or that the server rejected before execution (503), is known unsent and is
  re-sent after a short hold.
- Outcomes a caller can observe: a reply, a typed server error (`rpcError`),
  `commitOutcomeUnknown`, `CancellationError`, and its own deadline. The deadline is `timeout`
  when a session was open, `notConnected` when none was. `stopped` appears only when the
  account generation ends (logout, termination, share-extension finish).

`RequestLedger` holds all of this as a value type: facts in (`submit`, `connectionOpened`,
`connectionLost`, `prepared`, `sendSucceeded`/`sendFailed`, `acknowledged`, `replied`,
`commitOutcomeUnknown`, `rejectedBeforeExecution`, `deadlineReached`, `cancel`, `close`,
`wake`), commands out (`prepare`, `transmit`, `resolve`, `wake(after:)`). `ProtocolSession` is
its adapter: it runs `beforeDispatch`, writes to the transport, owns deadline and wake timers,
maps wire message IDs to ledger attempts and resumes continuations. Every rule above has a
pure schedule in `RealtimeV2Tests/RequestLedgerTests` and a transport-level check in
`RealtimeV2Tests/ProtocolSessionRequestTests`; add new rules there first.

When V3 gains a stable session identity with message-ID continuity, acked writes can join the
re-send path: the `readOnly` check in the ledger becomes a replay-safety check and nothing
else moves.

## Things that look wrong but are deliberate

- `ProtocolSession.reset()` runs on every transport disconnect and reports `connectionLost` to
  the ledger. It must not resolve pending requests; `closeDirectRequests()` does that and only
  the account-generation owners call it.
- `RealtimeV2` keeps one `ProtocolSession` across logout and re-login. The ledger therefore
  stays usable after `close`.
- Transactions do not use the ledger. They have their own durable queue with replay policy per
  method and an ack-aware `connectionLost` path in `Transactions.swift`.
- Attempt numbers in the ledger are global, not per request. Tests assert exact numbers.
