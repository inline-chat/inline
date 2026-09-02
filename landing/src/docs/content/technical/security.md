---
title: "Security"
description: "Realtime security and credential boundaries."
---

## Realtime V3

- TLS/WSS: certificate-validated network transport.
- Handshake: pinned RSA keys, RSA_PAD, finite-field DH, permanent keys, and bound temporary keys.
- Records: MTProto 2.0 KDF, AES-256-IGE, message keys, direction checks, replay rejection, and authenticated results.
- Dispatch: user, session, space, chat, bot, scope, and file authorization.
- Server termination: both encryption layers end at Inline's server; this is not end-to-end encryption.

References:

- [Protocol](/docs/technical/protocol)
- [V3 specification](https://github.com/inline-chat/inline/blob/main/packages/protocol/docs/realtime-v3.md)
- [Trust roots](https://github.com/inline-chat/inline/blob/main/packages/protocol/trust-roots/inline-protocol-production.json)
- [Conformance vectors](https://github.com/inline-chat/inline/blob/main/packages/protocol/vectors/inline-protocol-v1.json)

## Credentials

- Bot API: bot token.
- Realtime V2: Inline bearer token.
- Realtime V3: permanent and bound temporary keys.
- MCP: OAuth 2.1 with PKCE, scopes, and selected chat context.
- CLI: signed-in local CLI session.

Credentials are not interchangeable. Do not log tokens, keys, OAuth grants, webhook secrets, or local control credentials.

## Apple Database

The authenticated iOS and macOS account database uses SQLCipher with a 256-bit random key stored in Keychain with after-first-unlock accessibility. This does not cover every downloaded file or operating-system cache.

[Product security](/docs/security)
