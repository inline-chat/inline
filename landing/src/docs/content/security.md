---
title: "Security"
description: "Inline security and vulnerability reporting."
---

We'll be writing a more in-depth page here, but here's a summary:

- Security has been one of the most important aspects of the product for us, and we'll keep working in this area, improving and upgrading our security at every layer as well as privacy controls and spam mitigation mechanisms.
- We're using a secure encrypted transport, based on Telegram's MTProto 2, which gives us significantly better transport security than other work chat apps.
- iOS and macOS local databases are encrypted using SQLCipher.
- All message content is fully encrypted.
- Inline doesn't provide E2EE at the moment, but we do expect to have E2EE at least for DMs in the future if we can address the UX issues that come with it without sacrificing an easy-to-use and fast user experience.
- We may provide a self-hosting option for companies who have limitations around sending their data to a third party in the future.

More details soon. Feel free to ask us questions directly in the meantime.

## Technical Details

- [Inline Protocol](/docs/technical/protocol)
- [Technical Security](/docs/technical/security)
- [Local Agent Security](/docs/technical/local-agents#security)

## Report a Vulnerability

- Email [hey@inline.chat](mailto:hey@inline.chat). Use the subject **Security**.
- You can also DM @mo inside Inline to have a friendly chat!
