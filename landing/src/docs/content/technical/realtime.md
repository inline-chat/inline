---
title: "Realtime"
description: "Realtime V3 endpoint, connection lifecycle, and request outcomes."
---

Realtime V3 carries authenticated RPCs and live updates over a persistent WebSocket. Use `wss://api.inline.chat/realtime/v3` for Inline Protocol v1; the `/realtime` endpoint is the separate [V2 compatibility transport](/docs/technical/realtime-v2). This page is for client and integration authors who already have V3 credentials. See [Authentication](/docs/technical/authentication) to create them and [Protocol](/docs/technical/protocol) for the wire layers.

## Connect and resume

1. Open a WSS connection to `/realtime/v3`. The server admits a binary WebSocket and expects the obfuscated carrier header, followed by Inline Protocol records. It disables WebSocket per-message compression.
2. Establish a new authorization key or resume with a stored key. A resumed temporary key is probed before application traffic. An expired, revoked, or rotation-due temporary key requires a new temporary handshake and binding to the authorized permanent key.
3. Send typed `RealtimeV3Request` payloads in `inline.invoke`; receive `inline.result` and `inline.update`. The protocol wrapper does not change the Protocol Buffer schema in [`core.proto`](https://github.com/inline-chat/inline/blob/main/proto/core.proto).
4. On reconnect, restore authenticated transport first, then repair update gaps from authoritative cursors. A live connection alone does not prove local state is current; see [Sync](/docs/technical/sync).

The [TypeScript V3 transport](https://github.com/inline-chat/inline/blob/main/packages/sdk/src/realtime/v3-transport.ts) and [Rust V3 connection](https://github.com/inline-chat/inline/blob/main/crates/sdk/src/realtime_v3.rs) implement connection and rotation behavior. The high-level TypeScript SDK selects V3 with `inlineProtocol.credentials`, not with its `token` option. A bearer token cannot authenticate this endpoint.

## Authentication Lifecycle

Create a permanent authorization key with a pinned server public-key ring, authorize that key through native or hosted login, then create and bind a temporary key before application RPCs. Persist replacement credentials before admitting work on them, rotate temporary keys at the authenticated 80%-of-lifetime boundary, and clear local credentials during logout. The exact creation, binding, persistence, and revocation contract is in [Authentication](/docs/technical/authentication).

## Outcomes

Transport delivery and application completion are different events. In particular, an acknowledgment or successful carrier send does not establish that a mutation committed.

| Outcome | Meaning for a mutation | Next action |
|---|---|---|
| Not sent or rejected before execution | The request did not enter application execution. | Retry after fixing connectivity, admission, or rotation. |
| Accepted or dispatched | The server may have begun work; no result is confirmed. | Wait for the authenticated result. |
| Confirmed | An authenticated application result or method error arrived. | Handle that result; a method error is not a transport retry signal. |
| Commit outcome unknown | Dispatch occurred, but the authoritative result was lost or cannot be classified. | Reconcile server state or use a documented stable operation identity before retrying. |

Cancellation ends the local wait; it does not prove server execution stopped. The [RPC semantics](/docs/technical/rpc) page identifies repeat-safe identities and methods that require reconciliation. For media access and the upload lifecycle, see [Files](/docs/technical/files).

## References

- [TypeScript V3 connection](https://github.com/inline-chat/inline/blob/main/packages/sdk/src/realtime/v3-connection.ts) and [SDK options](https://github.com/inline-chat/inline/blob/main/packages/sdk/src/sdk/types.ts)
- [Server V3 WebSocket host](https://github.com/inline-chat/inline/blob/main/server/src/core/http/realtimeV3Host.ts)
- [Rust V3 connection](https://github.com/inline-chat/inline/blob/main/crates/sdk/src/realtime_v3.rs)
