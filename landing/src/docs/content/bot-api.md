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
| Header-authenticated method URL | `https://api.inline.chat/bot/<method>` |

## Authentication

- Header, recommended: `Authorization: Bearer <token>`
- Telegram-compatible path: `/bot<token>/<method>`

`@inline-chat/bot-client` uses header authentication by default. Set `authMode: "path"` only for a token-in-path adapter.

## First Message

1. [Create a bot](/docs/creating-a-bot) and provide its token as `INLINE_BOT_TOKEN` in your process environment or secret manager.
2. With no webhook or other polling consumer running for this bot, initialize polling:

```bash
curl -sS "https://api.inline.chat/bot/getUpdates?timeout=0" \
  -H "Authorization: Bearer ${INLINE_BOT_TOKEN}"
```

3. Open a direct message with that bot in Inline and send it a message yourself. Read the update with a long poll, allowing time for delivery:

```bash
curl -sS "https://api.inline.chat/bot/getUpdates?timeout=30" \
  -H "Authorization: Bearer ${INLINE_BOT_TOKEN}"
```

Initialize delivery before sending the test message: a fresh bot's queue is created on its first polling call or webhook setup, and earlier messages are not backfilled. An empty `result` on the first call is normal. If the long poll also returns empty, no matching update arrived during that interval; check the chat and try again.

Use `message.chat.chat_id` from a message update as `INLINE_CHAT_ID`. If a webhook is already active, send the test message to that integration and use the chat ID from its handler instead of starting another consumer.

### TypeScript Client

#### Bun

```bash
bun add @inline-chat/bot-client@^0.1.0
```

#### npm

```bash
npm install @inline-chat/bot-client@^0.1.0
```

Save this as `send.ts`. The chat ID is supplied as a decimal string, so it is not rounded by JavaScript numeric conversion:

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
console.log("Message accepted. Open the bot's chat in Inline to verify it.")
```

Run with [Bun](https://bun.sh):

```bash
bun run send.ts
```

The message should appear from your bot in the same direct message. This verifies authentication, chat access, and sending; running a responding bot also requires [receiving and processing updates](/docs/bot-updates).

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

Create a thread, then send its first message. Inputs: `title`, `emoji`, `space_id`, `is_public`, and `participants`. Private threads include the authenticated bot; public threads do not accept an explicit participant list. Initialize polling or webhooks first if you expect participation events or replies from the new thread.

This fragment uses the `bot` above. Set `userId` to the intended participant's numeric user ID before running it:

```ts
const userId = 42 // Replace with your own Inline user ID for a test.
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

Markdown user links become structured mentions. A bot with thread-management access may add or remove users, but cannot remove itself.

## Targeting Chats

- Use exactly one target per request: `chat_id` or `user_id`.
- Legacy `peer_thread_id` and `peer_user_id` targets are also accepted.

## Receiving Updates

Polling and webhooks consume the same pending queue. Enabling a webhook disables polling until `deleteWebhook`.

[Polling, webhook setup, acknowledgement, and recovery](/docs/bot-updates)

| Property | Contract |
| --- | --- |
| Retention | Up to 24 hours |
| Ordering | Increasing `update_id`; tolerate gaps and slight reordering |
| Polling | 1–100 updates; process in ID order and never advance the offset past failed work; one active long poll per bot |
| Queue limits | 100,000 updates, 128 MiB total, 512 KiB per update |
| Response limit | `getUpdates` returns about 4 MiB at most |
| Delivery | At least once; deduplicate with `update_id` |

When a queue limit is reached, the new update is dropped without blocking later delivery. `getWebhookInfo.dropped_update_count` reports cumulative drops. Use `drop_pending_updates: true` only when intentionally discarding the backlog.

For webhooks, verify `x-inline-bot-api-secret-token` when configured. Inline also sends `x-inline-update-id` and `x-inline-attempt`.

## Access Rules

- `getFile` and `file_id` reuse are limited to files uploaded by the bot or visible in an accessible message.
- Bots do not receive their own messages.
- With the default `mentions` trigger, humans activate a bot through user chats, mentions, replies, commands, and message actions. Bots must use an explicit resolved mention.

## Response Format

Success:

```json
{ "ok": true, "result": {} }
```

Error:

```json
{ "ok": false, "error_code": 400, "description": "Invalid arguments was provided" }
```

The typed client returns API failures as `ok: false`; check that field on every call. Network failures can reject the promise. Use `methodRaw` when you also need the HTTP status and headers. The client does not retry automatically. A lost response after a send does not prove the message was not sent; avoid blind retries that can duplicate it.

| Failure | Action |
| --- | --- |
| Authentication rejected | Verify a bot token with `getMe`; do not use the personal CLI session. |
| Invalid arguments or target | Check the generated method schema and use exactly one destination. |
| Access denied | Confirm the bot can access the target chat or file. |
| Retry requested | Honor a `Retry-After` response header when present and apply backoff; do not assume a Telegram-style `parameters.retry_after` field. |
| Poll conflict or webhook active | Use one delivery consumer. See [update recovery](/docs/bot-updates#troubleshooting). |

## Packages

- `@inline-chat/bot-client` — typed client and generated types
- `@inline-chat/bot-api-types` — generated request, response, method, and entity types
- [Realtime API](/docs/realtime-api) — connected clients and live state
