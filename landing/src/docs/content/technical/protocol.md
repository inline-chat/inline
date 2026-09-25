---
title: "Protocol"
description: "Inline Protocol v1 layers, records, and application payloads."
---

Inline Protocol v1 is the secure transport used by [Realtime V3](/docs/technical/realtime). It carries Inline RPCs and updates inside encrypted records over a binary WebSocket. This page explains the wire layers for implementers; use an SDK for ordinary client connections. Inline uses parts of the MTProto 2.0 construction, but its application schema and endpoint are Inline's own. A Telegram client cannot connect by changing its URL.

## About this page

For transport implementers. Read [the connection model](/docs/technical/realtime) and [key lifecycle](/docs/technical/authentication) first; you need binary framing and public-key cryptography knowledge to implement the wire layer. SDK users can skip the construction details.

**Applies to:** Inline Protocol v1 and Realtime V3. See the [version and example baseline](/docs/technical#versions-and-examples) before choosing a package.

## Layers

| Layer | Responsibility | What it carries |
|---|---|---|
| WebSocket | Network connection | Binary messages at `/realtime/v3` |
| Obfuscated abridged carrier | Frame boundaries and stream obfuscation | Abridged packets |
| Inline Protocol record | Handshake, encrypted records, message IDs, sequence numbers, and service messages | TL-encoded objects |
| Inline application | Distinguishes invocation, result, and update | `inline.invoke`, `inline.result`, `inline.update` |
| Application payload | Typed operations and updates | Exact Protocol Buffer bytes from `proto/core.proto` |

The carrier's obfuscation is not a substitute for TLS or record encryption. The WebSocket endpoint uses WSS; Inline's server terminates the protocol layer and can process its contents. See [Security](/docs/technical/security) for the trust boundary.

## Construction

The handshake selects a trusted, pinned server RSA public key and uses RSA_PAD, nonces, and validated finite-field Diffie–Hellman parameters to derive an authorization key. A permanent key is a device credential. An independently created temporary key can be bound to an authorized permanent key; see [Authentication](/docs/technical/authentication) for that lifecycle. A completed cryptographic handshake alone does not authorize application RPCs.

Encrypted records use the MTProto 2.0 message-key derivation and AES-256-IGE construction. A record includes an authorization-key ID, message key, server salt, session ID, message ID, sequence number, body length, body, and padding. Readers check the message key, direction, session, salt, time window, and shape before dispatch. Service messages provide acknowledgments, resend and state queries, salt and clock correction, and temporary-key binding. These mechanisms support recovery, but an acknowledgment is not proof that an application mutation committed. See [RPC semantics](/docs/technical/rpc) before retrying a mutation.

## Specification

The application wrapper's `layer` is `3` for Realtime V3. Its payload is the serialized `RealtimeV3Request`, `RealtimeV3Response`, or `RealtimeV3Update` message from [`core.proto`](https://github.com/inline-chat/inline/blob/main/proto/core.proto). Do not substitute a V2 `ClientMessage` frame inside this wrapper. WebSocket per-message compression is disabled for V3.

## Implementations

- [TypeScript handshake](https://github.com/inline-chat/inline/blob/main/packages/protocol/src/secure/handshake.ts), [record](https://github.com/inline-chat/inline/blob/main/packages/protocol/src/secure/record.ts), [carrier](https://github.com/inline-chat/inline/blob/main/packages/protocol/src/secure/carrier.ts), and [application wrapper](https://github.com/inline-chat/inline/blob/main/packages/protocol/src/secure/application.ts)
- [Rust secure transport](https://github.com/inline-chat/inline/blob/main/crates/protocol/src/secure.rs) and [Rust V3 connection](https://github.com/inline-chat/inline/blob/main/crates/sdk/src/realtime_v3.rs)
- [Conformance vectors](https://github.com/inline-chat/inline/blob/main/packages/protocol/vectors/inline-protocol-v1.json) and [production public-key ring](https://github.com/inline-chat/inline/blob/main/packages/protocol/trust-roots/inline-protocol-production.json)
- [MTProto 2.0 construction](https://core.telegram.org/mtproto/description) for the inherited cryptographic terminology; Inline's source and schema define Inline behavior

For endpoint selection and connection recovery, continue to [Realtime](/docs/technical/realtime).

## Summary

Use the SDK unless you need wire interoperability. A conforming transport validates records before dispatch and passes exact protobuf payloads to the application layer. Continue with [request outcomes](/docs/technical/realtime#outcomes) to distinguish record delivery from application completion.
