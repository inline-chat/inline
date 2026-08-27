---
title: "Security"
description: "Security posture, encryption, and vulnerability reporting."
---

Last updated: August 26, 2026.

## At a Glance

- We do not sell your data.
- Realtime V3 carries an MTProto 2.0-inspired encrypted protocol inside TLS/WSS.
- Sensitive cloud data is encrypted at rest.
- Authenticated Apple-device databases use SQLCipher with a random key stored in Keychain.
- Native releases are signed; direct macOS builds are notarized.

## Layered Realtime Security

Realtime V3 uses two encryption layers between the client and Inline's server:

1. TLS protects the WebSocket connection.
2. Inline Protocol v1 adds pinned server-key verification, permanent and bound temporary authorization keys, MTProto 2.0 record encryption, direction and replay checks, acknowledgements, and resend recovery.

This is defense in depth beyond relying on TLS alone. Inline Protocol is inspired by and byte-compatible with the relevant MTProto 2.0 secure-transport construction, while using Inline endpoints, trust roots, sessions, and application methods. See the [technical security model](/docs/technical/security) and [Inline Protocol](/docs/technical/protocol).

## Device Database Encryption

On iOS and macOS, Inline encrypts the authenticated account database with SQLCipher. The app generates a 256-bit database key with the system secure random generator and stores it in Apple Keychain with after-first-unlock protection.

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
