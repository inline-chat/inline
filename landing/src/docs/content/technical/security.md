---
title: "Security"
description: "Layered realtime transport, trust roots, credentials, and Apple device database encryption."
---

[Product security and vulnerability reporting](/docs/security)

## Realtime Defense in Depth

| Layer | Protection | Reference |
| --- | --- | --- |
| TLS/WSS | Server certificate validation and encrypted network transport | `wss://api.inline.chat/realtime/v3` |
| Inline Protocol handshake | Pinned server RSA keys, RSA_PAD, finite-field DH, permanent keys, and bound temporary keys | [Protocol construction](/docs/technical/protocol) |
| Inline Protocol records | MTProto 2.0 KDF, AES-256-IGE, message keys, direction checks, replay rejection, and authenticated results | [Normative V3 specification](https://github.com/inline-chat/inline/blob/main/packages/protocol/docs/realtime-v3.md) |
| Application dispatch | User, session, space, chat, bot, scope, and file authorization | [RPC semantics](/docs/technical/rpc) |

The Inline Protocol layer is independently authenticated and encrypted inside TLS. This is defense in depth beyond a TLS-only realtime transport. Inline's server terminates both layers, so this is not end-to-end encryption between user devices.

- [Production trust roots](https://github.com/inline-chat/inline/blob/main/packages/protocol/trust-roots/inline-protocol-production.json)
- [Frozen cross-language vectors](https://github.com/inline-chat/inline/blob/main/packages/protocol/vectors/inline-protocol-v1.json)
- [TypeScript secure transport](https://github.com/inline-chat/inline/tree/main/packages/protocol/src/secure)
- [Rust secure transport](https://github.com/inline-chat/inline/tree/main/crates/protocol/src/secure)

## Device Database Encryption

The authenticated iOS and macOS account database uses SQLCipher with a 256-bit random key stored in the Apple Keychain with after-first-unlock accessibility.

- [SQLCipher](https://www.zetetic.net/sqlcipher/)
- [SQLCipher.swift](https://github.com/sqlcipher/SQLCipher.swift)

Scope: the authenticated account database, not every downloaded file or operating-system cache.

## Surface Credentials

| Surface | Authentication |
| --- | --- |
| Bot API | Bot token in the Authorization header or compatibility path. Normal user-session tokens are not Bot API credentials. |
| Realtime compatibility API | Inline bearer token. |
| Realtime V3 | Inline Protocol permanent and bound temporary authorization keys. |
| MCP | OAuth 2.1 with PKCE, scopes, and selected chat context. |
| CLI | The signed-in user's local CLI session. |

Credentials are not interchangeable. Never log or publish bearer tokens, authorization keys, OAuth grants, webhook secrets, or local control credentials.
