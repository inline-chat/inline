# Security

Last updated: February 11, 2026.

Inline is in alpha and this page is still evolving. We're actively tightening security as we build.

## TL;DR

- We do not sell your data.
- Traffic is encrypted in transit (HTTPS/WSS over TLS).
- Sensitive cloud data is encrypted at rest.
- Local app data on Apple devices is encrypted.
- Client apps are open source.

## What We Do Today

- We ship frequent updates and security patches.
- Native releases are signed. macOS direct builds are notarized.
- We only ask for sensitive permissions when a feature needs them.
- We use service providers to run infrastructure, but we do not sell personal data.

## Will It Have End-to-End Encryption?

Short answer is not at launch. Let's go over our requirements. We want to offer the best work chat experience for teams and communities of all sizes. It has to be scalable for very large chats, stay fast and be secure at every layer.

Maximum security is end-to-end encryption which comes at a cost. For example, it makes it very difficult or impossible to sync history across devices and installs fast, securely especially across many large chats. Similarly, it impacts features like searching across all chats and file contents, AI agents, publicly sharing chat threads, real-time translation, etc. Even if it's possible to develop novel technical solutions to each of the limitations, it hasn't been done before practically in this context and it's beyond our resources as a very small startup right now.

For such reasons, we decided to instead focus on security at every layer (even encrypting the locally stored database on your iPhone or Mac similar to Signal). As we go, we'll keep exploring the options for even more security. For example, ephemeral messages or letting users selectively enable E2EE in certain chats/DMs while explicitly opting out of features like history sync or cloud search as a trade-off.

If you have suggestions, questions, or concerns, please reach out to [founders@inline.chat](mailto:founders@inline.chat).

## Report A Vulnerability

- Email: [hey@inline.chat](mailto:hey@inline.chat)
- Subject: Security
- Include clear reproduction steps and impact.
- Please avoid public disclosure until we have time to investigate and patch.
