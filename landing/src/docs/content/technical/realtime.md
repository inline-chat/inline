---
title: "Realtime"
description: "Realtime V3 transport, authentication, and outcomes."
---

- Endpoint: `wss://api.inline.chat/realtime/v3`
- Authentication: Inline Protocol permanent and bound temporary keys.
- Encoding: exact [`core.proto`](https://github.com/inline-chat/inline/blob/main/proto/core.proto) bytes.
- Carrier: obfuscated abridged frames over binary WebSocket.
- Compression: disabled.
- Bearer tokens do not authenticate V3.

## Authentication Lifecycle

1. Create a permanent key with the protocol handshake and pinned server keys.
2. Run `authBegin` and `authComplete` inside the encrypted session.
3. Create and bind a temporary key.
4. Rotate temporary keys before expiry.

Use the SDK implementation:

- [TypeScript V3 connection](https://github.com/inline-chat/inline/blob/main/sdk/src/realtime/v3-connection.ts)
- [TypeScript V3 transport](https://github.com/inline-chat/inline/blob/main/sdk/src/realtime/v3-transport.ts)
- [Rust V3 connection](https://github.com/inline-chat/inline/blob/main/crates/sdk/src/realtime_v3.rs)

## Outcomes

- `notSent`: rejected before carrier dispatch.
- `rejectedBeforeExecution`: execution provably did not begin.
- `accepted`: dispatched; not yet confirmed.
- `confirmed`: authenticated result or application error received.
- `commitUnknown`: execution may have begun; do not retry blindly.
- `reconciled`: stable identity or authoritative query found the result.

Cancellation stops the wait; it does not prove execution stopped.

## References

- [Protocol](/docs/technical/protocol)
- [RPC semantics](/docs/technical/rpc)
- [Sync](/docs/technical/sync)
- [Files](/docs/technical/files)
- [V3 specification](https://github.com/inline-chat/inline/blob/main/packages/protocol/docs/realtime-v3.md)
- [V2 compatibility](/docs/technical/realtime-v2)
