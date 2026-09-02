---
title: "Bot API"
description: "HTTP methods for Inline bots."
---

Inline has an easier to use HTTP API for creating bots. We recommend using this for most integration usages, unless you need advanced features and maximum control where you should use our full realtime API which is used in our own official clients.

## Bot API

- Version: `0.1`
- Base URL: `https://api.inline.chat`
- Method URL: `https://api.inline.chat/bot/<method>`
- [Method reference](https://api.inline.chat/bot-api-reference)
- [OpenAPI JSON](https://inline.chat/openapi.json)

## Authentication

Recommended header:

```text
Authorization: Bearer <token>
```

Simpler path for quick tests:

```text
https://api.inline.chat/bot<token>/<method>
```

## Receive a Chat ID

[Create a bot](/docs/creating-a-bot), set `INLINE_BOT_TOKEN`, and initialize its update queue before sending a test message:

```bash
curl -sS "https://api.inline.chat/bot/getUpdates?timeout=0" \
  -H "Authorization: Bearer ${INLINE_BOT_TOKEN}"
```

Send the bot a DM in Inline, then poll:

```bash
curl -sS "https://api.inline.chat/bot/getUpdates?timeout=30" \
  -H "Authorization: Bearer ${INLINE_BOT_TOKEN}"
```

Use `message.chat.chat_id` as `INLINE_CHAT_ID`. Messages sent before the first poll or webhook setup are not backfilled.

## TypeScript Client

Install with Bun:

```bash
bun add @inline-chat/bot-client@^0.1.0
```

Install with npm:

```bash
npm install @inline-chat/bot-client@^0.1.0
```

Set `INLINE_BOT_TOKEN` and `INLINE_CHAT_ID`. Save as `send.ts`:

```ts
import { InlineBotClient } from "@inline-chat/bot-client"

const token = process.env.INLINE_BOT_TOKEN
const chatId = process.env.INLINE_CHAT_ID
if (!token || !chatId) throw new Error("Set INLINE_BOT_TOKEN and INLINE_CHAT_ID")

const bot = new InlineBotClient({ token })
const me = await bot.getMe()
if (!me.ok) throw new Error(`${me.error_code}: ${me.description}`)

const sent = await bot.sendMessage({ chat_id: chatId, text: "Hello from my bot" })
if (!sent.ok) throw new Error(`${sent.error_code}: ${sent.description}`)
```

Run it:

```bash
bun run send.ts
```

## Methods

- Identity and chats: `getMe`, `getChat`, `getChatHistory`, `getMessages`, `searchMessages`
- Threads: `createThread`, `createReplyThread`, `addThreadParticipant`, `removeThreadParticipant`
- Messages: `sendMessage`, `editMessageText`, `deleteMessage`, `forwardMessage`, `sendReaction`
- Files: `uploadFile`, `getFile`
- Updates: `getUpdates`, `setWebhook`, `deleteWebhook`, `getWebhookInfo`

Use exactly one destination: `chat_id` or `user_id`. Legacy `peer_thread_id` and `peer_user_id` are accepted.

## Threads and Mentions

Create a private thread and send its first message:

```ts
const userId = 42
const created = await bot.createThread({
  title: "Support",
  participants: [userId],
})
if (!created.ok) throw new Error(created.description)

const reply = await bot.sendMessage({
  chat_id: created.result.chat.chat_id,
  text: `Hello [there](inline://user/${userId})`,
})
if (!reply.ok) throw new Error(reply.description)
```

- Public threads require a space and no participant list.
- Markdown mentions use `inline://user/{userId}`.
- A bot cannot remove itself from a thread.

## Updates

Polling and webhooks consume the same queue. Setting a webhook disables polling.

- Retention: up to 24 hours.
- Delivery: at least once; deduplicate by `update_id`.
- Batch: 1–100 updates.
- Queue: 100,000 updates, 128 MiB total, 512 KiB per update.
- Response: about 4 MiB maximum.
- Polling: one active long poll per bot.
- Webhook secret header: `x-inline-bot-api-secret-token`.

[Polling and webhooks](/docs/bot-updates)

## Files and Access

- `getFile` and `file_id` reuse require a bot-owned upload or an accessible message.
- Bots do not receive their own messages.
- Humans activate the default `mentions` trigger through DMs, mentions, replies, commands, and message actions.
- Bots activate other bots only with an explicit resolved mention.

## Responses

Success:

```json
{ "ok": true, "result": {} }
```

Error:

```json
{ "ok": false, "error_code": 400, "description": "Invalid arguments was provided" }
```

Check `ok` on every response. The client does not retry automatically. A lost send response may be an uncertain commit; do not retry blindly.

## Packages

- `@inline-chat/bot-client`: client and generated types.
- `@inline-chat/bot-api-types`: generated request, response, entity, and method types.
