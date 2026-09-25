---
title: "Realtime V2"
description: "Bearer-token compatibility transport and migration boundary."
---

Realtime V2 is the bearer-token compatibility path for live RPCs and updates. Connect to `wss://api.inline.chat/realtime` when using an existing V2 integration or the SDK's `token` option. New V3 credentials use the separate [Realtime V3](/docs/technical/realtime) transport.

## Connection contract

A V2 client opens a binary WebSocket and sends a Protocol Buffer `ClientMessage` containing `connection_init`. The `ConnectionInit.token` field authenticates the account or bot session. The server responds with `connection_open` after successful authentication; subsequent messages carry typed RPC calls, results, and updates. The token travels in the initial protocol message, not as a V3 authorization key. See [`core.proto`](https://github.com/inline-chat/inline/blob/main/proto/core.proto), the [server connection handler](https://github.com/inline-chat/inline/blob/main/server/src/realtime/handlers/_connectionInit.ts), and the [V2 WebSocket host](https://github.com/inline-chat/inline/blob/main/server/src/core/http/realtimeHost.ts).

The [TypeScript V2 quick start](/docs/realtime-api#v2-quick-start) shows SDK setup and a send operation. The [Rust V2 client](https://github.com/inline-chat/inline/blob/main/crates/sdk/src/realtime.rs) also accepts a URL and token. Store bearer tokens as secrets and limit the identity's access to the chats it needs.

## V2 and V3 are separate transports

| Concern | V2 | V3 |
|---|---|---|
| Endpoint | `/realtime` | `/realtime/v3` |
| Authentication | Bearer token in `connection_init` | Authorized permanent key and bound temporary key |
| WebSocket payload | Protocol Buffer `ClientMessage` and `ServerProtocolMessage` | Inline Protocol records carrying typed application payloads |
| TypeScript SDK selection | `token` | `inlineProtocol.credentials` |

Changing the endpoint or copying a V2 frame to V3 does not migrate credentials or framing. Follow the [V3 authentication lifecycle](/docs/technical/authentication) before switching a client. For uncertain mutation outcomes on either transport, use [RPC semantics](/docs/technical/rpc) rather than treating reconnect as proof of failure.
