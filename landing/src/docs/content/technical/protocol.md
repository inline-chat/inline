---
title: "Protocol"
description: "Inline Protocol v1, its MTProto 2.0 basis, wire construction, and implementations."
---

Inline Protocol v1 is the secure transport used by Realtime V3. It is inspired by and byte-compatible with the relevant MTProto 2.0 secure-transport construction; Inline endpoints, trust roots, authorization state, application constructors, and RPCs are distinct.

## Construction

| Part | Inline Protocol v1 |
| --- | --- |
| Handshake | Pinned RSA key verification, RSA_PAD, finite-field DH, nonce and transcript validation |
| Records | MTProto 2.0 KDF, AES-256-IGE, message key, server salt, session ID, message ID, sequence number, direction checks |
| Authorization | Permanent device key plus bound temporary keys; current temporary lifetime is 24 hours with rotation at 80% |
| Reliability | Containers, acknowledgements, resend and state requests, cached RPC results, clock correction, replay rejection |
| Carrier | Telegram-compatible obfuscated abridged framing and quick acknowledgements over binary WebSocket |
| Application | `inline.invoke`, `inline.result`, and `inline.update` wrap exact Inline Schema Protocol Buffer bytes |

MTProto 1.0 compatibility machinery is excluded except for the temporary-key binding encoding required by MTProto 2.0. Inline Protocol does not connect to Telegram.

## Telegram References

- [MTProto 2.0 description](https://core.telegram.org/mtproto/description)
- [Creating an authorization key](https://core.telegram.org/mtproto/auth_key)
- [Transport protocols](https://core.telegram.org/mtproto/mtproto-transports)
- TDLib symbols: [`AuthKey`](https://github.com/tdlib/td/blob/master/td/mtproto/AuthKey.h), [`DhHandshake`](https://github.com/tdlib/td/blob/master/td/mtproto/DhHandshake.cpp), and [`KDF`](https://github.com/tdlib/td/blob/master/td/mtproto/KDF.cpp)
- [Telegram-iOS MtProtoKit](https://github.com/TelegramMessenger/Telegram-iOS/tree/master/submodules/MtProtoKit)

These references describe the construction; Inline does not implement Telegram APIs or endpoints.

## Inline Implementations

### TypeScript

- [Secure transport exports](https://github.com/inline-chat/inline/tree/main/packages/protocol/src/secure)
- [`InlineHandshakeClient`](https://github.com/inline-chat/inline/blob/main/packages/protocol/src/secure/handshake.ts)
- [Encrypted records](https://github.com/inline-chat/inline/blob/main/packages/protocol/src/secure/record.ts)
- [Obfuscated abridged carrier](https://github.com/inline-chat/inline/blob/main/packages/protocol/src/secure/carrier.ts)
- [Realtime V3 connection](https://github.com/inline-chat/inline/blob/main/sdk/src/realtime/v3-connection.ts)

### Rust

- [Secure transport module](https://github.com/inline-chat/inline/blob/main/crates/protocol/src/secure.rs)
- [Handshake](https://github.com/inline-chat/inline/tree/main/crates/protocol/src/secure/handshake)
- [Carrier](https://github.com/inline-chat/inline/blob/main/crates/protocol/src/secure/carrier.rs)
- [Realtime V3 SDK connection](https://github.com/inline-chat/inline/blob/main/crates/sdk/src/realtime_v3.rs)

### Review Material

- [Normative protocol and Realtime V3 specification](https://github.com/inline-chat/inline/blob/main/packages/protocol/docs/realtime-v3.md)
- [Frozen cross-language conformance vectors](https://github.com/inline-chat/inline/blob/main/packages/protocol/vectors/inline-protocol-v1.json)
- [Production trust roots](https://github.com/inline-chat/inline/blob/main/packages/protocol/trust-roots/inline-protocol-production.json)

[Security](/docs/technical/security) · [Realtime](/docs/technical/realtime)
