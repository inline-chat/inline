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

## SDK Entry Points

- TypeScript: [`InlineSdkClient`](https://github.com/inline-chat/inline/blob/main/sdk/src/sdk/inline-sdk-client.ts), [V3 connection](https://github.com/inline-chat/inline/blob/main/sdk/src/realtime/v3-connection.ts), and [V3 transport](https://github.com/inline-chat/inline/blob/main/sdk/src/realtime/v3-transport.ts).
- Rust: [V3 connection](https://github.com/inline-chat/inline/blob/main/crates/sdk/src/realtime_v3.rs) and [`inline-client`](https://github.com/inline-chat/inline/tree/main/crates/client).
- RPC behavior: [normative replay and reconciliation matrix](https://github.com/inline-chat/inline/blob/main/packages/protocol/docs/realtime-v3-rpc-semantics.md).

## Outcomes

| Outcome | Meaning |
| --- | --- |
| Not sent | Safe to retry; the request was not dispatched. |
| Accepted | Dispatched, but not yet confirmed as user-visible success. |
| Confirmed | An authenticated result or authoritative update confirmed the result. |
| Commit unknown | The connection was lost after dispatch; blind retry may duplicate work. |
| Reconciled | A stable identity or query determined the committed result. |

[Method replay and reconciliation map](/docs/technical/rpc)

## Related Contracts

- [Sync](/docs/technical/sync) defines update ownership, cursors, catch-up, and gap repair.
- [Files](/docs/technical/files) defines resumable uploads and file-access boundaries.
- [Schema](/docs/technical/schema) links the application and protocol schemas.

## V2 Compatibility

The bearer-token endpoint at `/realtime` remains available for compatibility and is omitted from the sidebar. [V2 notes](/docs/technical/realtime-v2) · [Bearer-token quick start](/docs/realtime-api)
