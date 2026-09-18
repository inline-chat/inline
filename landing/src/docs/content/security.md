---
title: "Security"
description: "Inline security and vulnerability reporting."
---

We'll be writing a more in-depth page soon, but here's a summary:

- Inline is in beta, and security has been one of the most important aspects of the product for us. We'll keep improving security at every layer, alongside privacy controls and spam mitigation mechanisms.
- We use a secure encrypted transport based on Telegram's MTProto 2, giving Inline a strong foundation for transport security.
- iOS and macOS local databases are encrypted using SQLCipher.
- Message text and related content are stored encrypted. Before GA, we're continuing to expand this coverage by encrypting files ourselves before storing them with Cloudflare, alongside more thread and space metadata and settings.
- E2EE is on our roadmap, at least for DMs, once we can address its UX challenges without sacrificing an easy-to-use and fast experience.
- We're also planning a self-hosting option for companies that have limitations around sending data to a third party.

More details soon. Feel free to ask us questions directly in the meantime.

## Technical Details

- [Inline Protocol](/docs/technical/protocol)
- [Technical Security](/docs/technical/security)
- [Local Agent Security](/docs/technical/local-agents#security)

## Report a Vulnerability

- Email [hey@inline.chat](mailto:hey@inline.chat). Use the subject **Security**.
- You can also DM @mo inside Inline to have a friendly chat!
