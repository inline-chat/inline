---
title: "Deep Links"
description: "Construct Inline navigation links and distinguish destinations from mentions and invitations."
---

A deep link names a destination in Inline: a person, conversation, message, or space join flow. Use app links when the receiving device has Inline installed; use the supported HTTPS forms when sharing a web entry point.

`in://` is the canonical production scheme. `inline://` is a supported production alias. Development builds can use separate configured schemes; do not distribute those as production links.

## Identifiers and Access

Use positive decimal signed 64-bit IDs. Keep message identity as `(chatId, messageId)`, since the message ID alone does not identify its conversation. When constructing links in JavaScript, use decimal strings or `bigint` rather than converting large IDs through `number`.

Opening a person, chat, or message link does not grant access to that destination. A join link enters a separate admission flow: the server decides whether the public space or invitation permits joining. Treat private invitation tokens as credentials for that flow.

## App Links

| Destination | Canonical form |
| --- | --- |
| Person or bot | `in://user/{userId}` |
| Conversation | `in://chat/{chatId}` |
| Message | `in://chat/{chatId}/message/{messageId}` |
| Public space join | `in://join/public/{spaceHandle}` |
| Invitation join | `in://join/invite/{inviteToken}` |

Use the space handle or invitation token returned by Inline. The app parser accepts public handles of 2–64 ASCII letters, digits, underscores, or hyphens, beginning with a letter or digit. Current invitation tokens have the `iv1_` prefix and 47 characters in total; treat the complete token as opaque.

### Construct a Message Link

This TypeScript example runs in Bun and prints a URL without opening Inline. Replace both IDs with the destination values:

```ts
const chatId = 123n
const messageId = 456n
const maxId = (1n << 63n) - 1n
if (chatId <= 0n || messageId <= 0n || chatId > maxId || messageId > maxId) {
  throw new Error("Chat and message IDs must be positive signed 64-bit integers")
}
const url = new URL(`in://chat/${chatId}/message/${messageId}`)
console.log(url.href)
```

The output is `in://chat/123/message/456`. Verify a real link with an account that can access the destination. A well-formed URL proves only that the destination can be represented.

## Web Links

| Destination | HTTPS form |
| --- | --- |
| Conversation | `https://inline.chat/c/{chatId}` |
| Public space | `https://inline.chat/s/{spaceHandle}` |
| Invitation | `https://inline.chat/invite/{inviteToken}` |

The app's link generator has no HTTPS form for an individual user or message. Use the corresponding app link; do not invent a message suffix for `/c/{chatId}`.

## Accepted Aliases

- Scheme: `inline://`
- Chat host: `thread`
- User query keys: `id`, `user_id`, `userId`
- Chat query keys: `id`, `chat_id`, `chatId`, `thread_id`, `threadId`
- Message query keys: `message_id`, `messageId`
- Message path alias: `in://thread/{chatId}/message/{messageId}`

Prefer canonical path forms when generating new links. Accept aliases when reading existing links; query key matching in the app parser is case-insensitive.

## Markdown Mentions

An app navigation link and a structured mention have different jobs. For a mention inside a message, use the Markdown form `[@Name](inline://user/{userId})`. The message parser resolves it to an identity and produces mention metadata; a visible `@Name` alone is not that metadata.

Use `inline://user/{userId}` for this Markdown contract. For supported formatting, see [Inline Markdown](https://github.com/inline-chat/inline/blob/main/packages/protocol/docs/markdown.md).

## Reference

- [App parser and link generator](https://github.com/inline-chat/inline/blob/main/apple/InlineKit/Sources/InlineKit/DeepLinks/InlineDeepLink.swift): accepted routes, validation, and generated URLs.
- [Deep-link tests](https://github.com/inline-chat/inline/blob/main/apple/InlineKit/Tests/InlineKitTests/InlineDeepLinkTests.swift): canonical forms and compatibility cases.
- [Schema conventions](/docs/technical/schema): ID ranges and message identity.
