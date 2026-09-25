---
title: "Technical Security"
description: "Transport trust, authorization, credential, and local-storage boundaries."
---

Inline's realtime transports protect connections to Inline's service. They are not end-to-end encryption: the Inline Protocol layer terminates at the server, which processes RPCs and updates. This page identifies the boundaries an integration must preserve. For user-facing security information and vulnerability reporting, see [Product security](/docs/security).

## Realtime V3

Realtime V3 uses WSS plus Inline Protocol v1 records. The client must use a trusted server RSA public-key ring for the protocol handshake. The shipped TypeScript and Rust V3 clients include Inline's production public keys; custom-server clients must supply the correct trusted ring for that server. The public-key ring is verification material, not a login secret. The handshake validates the selected key and DH exchange; encrypted records validate key ID, message key, direction, session, salt, time window, and shape before application dispatch. See [Protocol](/docs/technical/protocol) and the [production trust roots](https://github.com/inline-chat/inline/blob/main/packages/protocol/trust-roots/inline-protocol-production.json).

The obfuscated carrier hides the abridged framing pattern. It does not replace WSS or the encrypted record layer. Inline can access content after transport termination; do not describe V3 as end-to-end encryption.

## Credentials

| Surface | Credential | Authorization boundary |
|---|---|---|
| Realtime V3 | Authorized permanent key plus bound temporary key | Server associates the binding with a user and account session, then checks current authority before RPC execution. |
| Realtime V2 | Bearer token | Server authenticates `connection_init`, then applies operation access checks. |
| Bot API | Bot token | Bot identity and its permitted chats and operations. |
| MCP | OAuth grant | Granted scopes and selected resource context. |

These credentials are not interchangeable. A completed V3 handshake does not grant application access, and a V2 bearer token cannot authenticate `/realtime/v3`. Within an authenticated session, each RPC still needs its operation-specific access checks; authentication does not grant access to every space, chat, file, or bot. See [Authentication](/docs/technical/authentication) for key creation, persistence, rotation, and revocation, and [server application admission](https://github.com/inline-chat/inline/blob/main/server/src/modules/inlineProtocol/application.ts) for the V3 authority check.

Treat tokens, authorization keys, OAuth grants, and local control credentials as secrets. Do not put them in logs, URLs, screenshots, or client-visible diagnostics. Revocation can race with an in-flight request; a lost result remains a [commit-unknown outcome](/docs/technical/realtime#outcomes), not proof that execution stopped.

## Apple Database

For an authenticated iOS or macOS account, `AppDatabase` opens the account database through SQLCipher. `DatabaseKeyStore` generates 32 random bytes for a new database passphrase, stores its Base64 representation in Keychain with after-first-unlock accessibility, and supplies that string to SQLCipher. The app also has migration and unavailable-Keychain paths for older local databases; the key-store behavior should not be generalized to every app file or startup state. This database protection does not cover every downloaded file, operating-system cache, or server copy.

See the [database configuration](https://github.com/inline-chat/inline/blob/main/apple/InlineKit/Sources/InlineKit/Database.swift), [database key store](https://github.com/inline-chat/inline/blob/main/apple/InlineKit/Sources/Auth/DatabaseKeyStore.swift), and [Keychain accessibility mapping](https://github.com/inline-chat/inline/blob/main/apple/InlineKit/Sources/Auth/KeychainStore.swift). For local agent boundaries, see [Local agent security](/docs/technical/local-agents#security).
