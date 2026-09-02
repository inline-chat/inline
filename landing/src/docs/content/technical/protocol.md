---
title: "Protocol"
description: "Inline Protocol v1 construction and implementations."
---

Inline Protocol v1 carries Realtime V3. It uses the MTProto 2.0 secure-transport construction with Inline endpoints, keys, sessions, schema, and RPCs.

## Construction

- Handshake: pinned RSA keys, RSA_PAD, finite-field DH, nonces, and transcript validation.
- Records: MTProto 2.0 KDF, AES-256-IGE, message keys, salts, sessions, message IDs, sequences, and direction checks.
- Authorization: permanent device key plus bound temporary keys.
- Temporary keys: 24-hour lifetime; rotate at 80%.
- Reliability: containers, ACKs, resend/state requests, cached results, clock correction, and replay rejection.
- Carrier: obfuscated abridged framing over binary WebSocket.
- Application: `inline.invoke`, `inline.result`, and `inline.update` contain Protocol Buffer bytes.
- No Telegram API or endpoint compatibility.

## Specification

- [Inline Protocol and Realtime V3](https://github.com/inline-chat/inline/blob/main/packages/protocol/docs/realtime-v3.md)
- [Conformance vectors](https://github.com/inline-chat/inline/blob/main/packages/protocol/vectors/inline-protocol-v1.json)
- [Production trust roots](https://github.com/inline-chat/inline/blob/main/packages/protocol/trust-roots/inline-protocol-production.json)
- [MTProto 2.0](https://core.telegram.org/mtproto/description)

## Implementations

- [TypeScript secure transport](https://github.com/inline-chat/inline/tree/main/packages/protocol/src/secure)
- [TypeScript V3 connection](https://github.com/inline-chat/inline/blob/main/sdk/src/realtime/v3-connection.ts)
- [Rust secure transport](https://github.com/inline-chat/inline/blob/main/crates/protocol/src/secure.rs)
- [Rust V3 connection](https://github.com/inline-chat/inline/blob/main/crates/sdk/src/realtime_v3.rs)
