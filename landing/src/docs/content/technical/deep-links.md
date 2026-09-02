---
title: "Deep Links"
description: "Inline app and web link formats."
---

Use positive decimal IDs. `in://` is canonical; `inline://` is a supported production alias.

## App Links

```text
in://user/{userId}
in://chat/{chatId}
in://chat/{chatId}/message/{messageId}
in://join/public/{spaceHandle}
in://join/invite/{inviteToken}
```

## Web Links

```text
https://inline.chat/c/{chatId}
https://inline.chat/s/{spaceHandle}
https://inline.chat/invite/{inviteToken}
```

## Accepted Aliases

- Scheme: `inline://`
- Chat host: `thread`
- User query keys: `id`, `user_id`, `userId`
- Chat query keys: `id`, `chat_id`, `chatId`, `thread_id`, `threadId`
- Message query keys: `message_id`, `messageId`
- Message path alias: `in://thread/{chatId}/message/{messageId}`

Opening a link does not grant access. Store chat and message IDs together.

Markdown mentions use `inline://user/{userId}`, not `in://user/{userId}`.
