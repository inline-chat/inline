# Security

Source: https://inline.chat/docs/security

Last updated: February 11, 2026.

## TL;DR

- We do not sell your data.
- Traffic is encrypted in transit (HTTPS/WSS over TLS).
- Sensitive cloud data is encrypted at rest.
- Local app data on Apple devices is encrypted.

## What We Do Today

- We ship frequent updates and security patches.
- Native releases are signed. macOS direct builds are notarized.
- We only ask for sensitive permissions when a feature needs them.
- We use service providers to run infrastructure, but we do not sell personal data.

## Will It Have End-to-End Encryption?

Not at launch.

Inline is optimizing first for fast sync, search, large chats, shared threads, and agent workflows. End-to-end encryption makes those features harder to support well across devices and teams.

For launch, we are focusing on security at every layer: encrypted transport, encrypted cloud storage, signed native apps, and encrypted local app data on Apple devices. We will keep exploring stronger options, including ephemeral messages or selectively encrypted chats with clear feature trade-offs.

If you have suggestions, questions, or concerns, please reach out to [founders@inline.chat](mailto:founders@inline.chat).

## Report A Vulnerability

- Email: [hey@inline.chat](mailto:hey@inline.chat)
- Subject: Security
- Include clear reproduction steps and impact.
- Please avoid public disclosure until we have time to investigate and patch.
