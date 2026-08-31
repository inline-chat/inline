---
title: "Realtime"
description: "Realtime V3 application RPCs, endpoints, SDKs, outcomes, and compatibility."
---

Realtime V3 carries Inline Schema through Inline Protocol v1 at `wss://api.inline.chat/realtime/v3`.

## Stack

| Layer | Contract | Reference |
| --- | --- | --- |
| Application | Typed methods, results, and updates | [`core.proto`](https://github.com/inline-chat/inline/blob/main/proto/core.proto) |
| Encoding | Exact Protocol Buffer bytes | [`@inline-chat/protocol`](https://github.com/inline-chat/inline/tree/main/packages/protocol) |
| Secure protocol | Authorization keys, encryption, replay checks, ACKs, and recovery | [Protocol](/docs/technical/protocol) |
| Carrier | Obfuscated abridged frames over binary WebSocket | [TypeScript carrier](https://github.com/inline-chat/inline/blob/main/packages/protocol/src/secure/carrier.ts) |
| Network | `wss://api.inline.chat/realtime/v3` | [Normative V3 specification](https://github.com/inline-chat/inline/blob/main/packages/protocol/docs/realtime-v3.md) |

V3 uses permanent and bound temporary authorization keys; bearer tokens do not authorize V3 sessions.

## Authentication Lifecycle

1. Establish a permanent authorization key using the protocol handshake and pinned server verification keys.
2. Run the native `authBegin` / `authComplete` login flow inside that encrypted session. The challenge is bound to the permanent key; completion binds the key to an Inline account session without returning a bearer token.
3. Create a temporary key and bind it to the permanent key before sending ordinary application RPCs. Rotate temporary keys before expiry.

A bearer token in HTTP headers or `ConnectionInit` cannot replace this flow. Use the SDK's V3 implementation rather than pointing a V2 bearer-token client at `/realtime/v3`.

The carrier uses binary WebSocket frames with compression disabled. Protocol acknowledgements and resend recovery belong to Inline Protocol, not to WebSocket connection status. [Handshake and carrier contract](https://github.com/inline-chat/inline/blob/main/packages/protocol/docs/realtime-v3.md)

## SDK Entry Points

- TypeScript: [`InlineSdkClient`](https://github.com/inline-chat/inline/blob/main/sdk/src/sdk/inline-sdk-client.ts), [V3 connection](https://github.com/inline-chat/inline/blob/main/sdk/src/realtime/v3-connection.ts), and [V3 transport](https://github.com/inline-chat/inline/blob/main/sdk/src/realtime/v3-transport.ts).
- Rust: [V3 connection](https://github.com/inline-chat/inline/blob/main/crates/sdk/src/realtime_v3.rs) and [`inline-client`](https://github.com/inline-chat/inline/tree/main/crates/client).
- RPC behavior: [normative replay and reconciliation matrix](https://github.com/inline-chat/inline/blob/main/packages/protocol/docs/realtime-v3-rpc-semantics.md).

## Outcomes

| Outcome | Meaning |
| --- | --- |
| Not sent | The request was rejected before carrier dispatch. Correct the cause before retrying. |
| Rejected before execution | The owner proved application execution did not begin, such as a capacity rejection. |
| Accepted | Dispatched, but not yet confirmed as user-visible success. |
| Confirmed | A matching authenticated result or application error arrived. Inspect it; confirmation does not always mean success. |
| Commit unknown | Execution may have begun, but no authoritative result arrived; blind retry may duplicate work. |
| Reconciled | A stable identity or query determined the committed result. |

[Method replay and reconciliation map](/docs/technical/rpc)

Cancellation stops waiting for an answer; it does not prove the server stopped executing. Reconcile mutations through their stable identity or an authoritative query/update before deciding to retry.

## Related Contracts

- [Sync](/docs/technical/sync) defines update ownership, cursors, catch-up, and gap repair.
- [Files](/docs/technical/files) defines resumable uploads and file-access boundaries.
- [Schema](/docs/technical/schema) links the application and protocol schemas.

## V2 Compatibility

The bearer-token endpoint at `/realtime` remains available for compatibility and is omitted from the sidebar. [V2 notes](/docs/technical/realtime-v2) · [Bearer-token quick start](/docs/realtime-api)
