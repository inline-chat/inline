---
title: "Security"
description: "Security posture, encryption, and vulnerability reporting."
---

Last updated: August 30, 2026.

## At a Glance

- We do not sell your data.
- Realtime V3 carries an MTProto 2.0-inspired encrypted protocol inside TLS/WSS.
- Selected message content and media metadata are encrypted by the application before storage.
- Authenticated Apple-device databases use SQLCipher with a random key stored in Keychain.
- Native releases are signed; direct macOS builds are notarized.

## Layered Realtime Security

Realtime V3 uses two encryption layers between the client and Inline's server:

1. TLS protects the WebSocket connection.
2. Inline Protocol v1 adds pinned server-key verification, permanent and bound temporary authorization keys, MTProto 2.0 record encryption, direction and replay checks, acknowledgements, and resend recovery.

This is defense in depth beyond relying on TLS alone. Inline Protocol is inspired by and byte-compatible with the relevant MTProto 2.0 secure-transport construction, while using Inline endpoints, trust roots, sessions, and application methods. See the [technical security model](/docs/technical/security) and [Inline Protocol](/docs/technical/protocol).

## Stored Data

Application-level encryption covers selected content such as new message text and formatting, rich message payloads, and some file and link-preview metadata. It does not cover all metadata or uploaded file bytes. This describes application-level protection, not storage-provider or backup controls. Inline's servers can decrypt content to provide the service; this is not end-to-end encryption.

## Device Database Encryption

On iOS and macOS, Inline encrypts the authenticated account database with SQLCipher. The app generates a 256-bit database key with the system secure random generator and stores it in Apple Keychain with after-first-unlock protection.

This covers the account database, not every downloaded file, exported transcript, or operating-system cache.

## Chats and Integrations

- Treat a public space thread as internet-accessible. Do not put confidential content there on the assumption that only space members can read it.
- A private thread's access rules and your personal follow/notification settings are separate. Closing or unfollowing a thread does not revoke someone else's access.
- A bot or connected agent can process the content it is permitted to read. Its operator and model provider have their own data-handling policies.
- MCP grants are scoped by OAuth consent. A local agent's workspace and command authority come from its bridge/provider policy, not from chat membership.

See [chat visibility](/docs/chats-and-threads#who-can-read-a-thread), [MCP access](/docs/mcp), and [local agent security](/docs/technical/local-agents#security).

## Release Security

- We ship frequent updates and security patches.
- We only ask for sensitive permissions when a feature needs them.
- We use service providers to run infrastructure, but we do not sell personal data.

## Will It Have End-to-End Encryption?

Not at launch.

Inline is optimizing first for fast sync, search, large chats, shared threads, and agent workflows. End-to-end encryption makes those features harder to support well across devices and teams.

Inline servers terminate the protocol so sync, search, large chats, shared threads, and agent workflows can work across devices. The two transport layers are therefore not end-to-end encryption and should not be compared with Signal-style E2EE by counting encryption layers. They provide strong client-to-server authentication and transport protection while preserving Inline's server-backed features.

We will keep exploring stronger options, including ephemeral messages or selectively encrypted chats with clear feature trade-offs.

If you have suggestions, questions, or concerns, please reach out to [founders@inline.chat](mailto:founders@inline.chat).

## Report A Vulnerability

- Email: [hey@inline.chat](mailto:hey@inline.chat)
- Subject: Security
- Include clear reproduction steps and impact.
- Please avoid public disclosure until we have time to investigate and patch.
