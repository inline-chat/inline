---
title: "Bot API"
description: "HTTP API for bot integrations and automations."
---

Inline Bot API is an HTTP interface for bots, serverless agents, and webhook workflows.

**Reference:** [Bot API methods and schemas](https://api.inline.chat/bot-api-reference) · [OpenAPI JSON](https://inline.chat/openapi.json)

| Contract | Value |
| --- | --- |
| Version | `0.1` |
| Base URL | `https://api.inline.chat` |

## Authentication

- Header, recommended: `Authorization: Bearer <token>`
- Telegram-compatible path: `/bot<token>/<method>`

`@inline-chat/bot-client` uses header authentication by default. Set `authMode: "path"` only for a token-in-path adapter.

## TypeScript Client

```sh
npm install @inline-chat/bot-client@^0.1.0
```

```ts
import { InlineBotClient } from "@inline-chat/bot-client"

const bot = new InlineBotClient({ token: process.env.INLINE_BOT_TOKEN! })
const result = await bot.sendMessage({ chat_id: 42, text: "hello" })
if (!result.ok) throw new Error(result.description)
```

## Common Methods

| Area | Methods |
| --- | --- |
| Identity and chats | `getMe`, `getChat`, `getChatHistory`, `getMessages`, `searchMessages` |
| Threads | `createThread`, `createReplyThread`, `addThreadParticipant`, `removeThreadParticipant` |
| Messages | `sendMessage`, `editMessageText`, `deleteMessage`, `forwardMessage`, `sendReaction` |
| Files | `uploadFile`, `getFile` |
| Updates | `getUpdates`, `setWebhook`, `deleteWebhook`, `getWebhookInfo` |

The [generated reference](https://api.inline.chat/bot-api-reference) lists every method, request, response, and entity.

Chats have `type: "user" | "thread"`. A reply thread may contain `parent_chat_id` and `parent_message`. The embedded parent is a normal message encoded once; its chat does not recursively include another parent message.

## Create a Thread and Start the Conversation

Create a thread, then send its first message. Inputs: `title`, `emoji`, `space_id`, `is_public`, and `participants`. Private threads include the authenticated bot; public threads do not accept an explicit participant list.

```ts
const created = await bot.createThread({
  title: "Support",
  participants: [userId],
})

if (created.ok) {
  const chatId = created.result.chat.chat_id
  await bot.sendMessage({
    chat_id: chatId,
    text: `Hello [@Mo](inline://user/${userId})`,
  })
}
```

Markdown user links become structured mentions. A bot with thread-management access may add or remove users, but cannot remove itself.

## Targeting Chats

- Use exactly one target per request: `chat_id` or `user_id`.
- Legacy `peer_thread_id` and `peer_user_id` targets are also accepted.

## Receiving Updates

Polling and webhooks consume the same pending queue. Enabling a webhook disables polling until `deleteWebhook`.

```ts
await bot.setWebhook({
  url: "https://agent.example.com/inline",
  secret_token: process.env.INLINE_WEBHOOK_SECRET,
  message_trigger: "mentions",
})
```

| Property | Contract |
| --- | --- |
| Retention | Up to 24 hours |
| Ordering | Increasing `update_id`; tolerate gaps and slight reordering |
| Polling | 1–100 updates; acknowledge with an offset above the highest processed ID; one active long poll per bot |
| Queue limits | 100,000 updates, 128 MiB total, 512 KiB per update |
| Response limit | `getUpdates` returns about 4 MiB at most |
| Delivery | At least once; deduplicate with `update_id` |

When a queue limit is reached, the new update is dropped without blocking later delivery. `getWebhookInfo.dropped_update_count` reports cumulative drops. Use `drop_pending_updates: true` only when intentionally discarding the backlog.

For webhooks, verify `x-inline-bot-api-secret-token` when configured. Inline also sends `x-inline-update-id` and `x-inline-attempt`.

## Access Rules

- `getFile` and `file_id` reuse are limited to files uploaded by the bot or visible in an accessible message.
- Bots do not receive their own messages.
- With the default `mentions` trigger, humans activate a bot through user chats, mentions, replies, commands, and message actions. Bots must use an explicit resolved mention.

## Quick Example

```bash
curl -sS \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -X POST "https://api.inline.chat/bot/sendMessage" \
  -d '{"chat_id":42,"text":"hello"}'
```

## Response Format

Success:

```json
{ "ok": true, "result": {} }
```

Error:

```json
{ "ok": false, "error_code": 400, "description": "Invalid arguments was provided" }
```

## Packages

- `@inline-chat/bot-client` — typed client and generated types
- `@inline-chat/bot-api-types` — generated request, response, method, and entity types
- [Realtime API](/docs/realtime-api) — connected clients and live state
