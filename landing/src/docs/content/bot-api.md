---
title: "Bot API"
description: "Authenticate a bot, receive a destination, and send messages through Inline's HTTP API."
---

The Bot API lets an integration read conversations, send messages, manage threads, and receive events as an Inline bot. Each request uses the bot's token; your application handles incoming updates through polling or a webhook.

Start with this API for HTTP integrations. Use the [Realtime API](/docs/realtime-api) when you need a persistent connection and synchronized client state. To connect an existing agent runtime, follow [Set Up an Agent](/docs/agents).

For your first request, [create a bot](/docs/creating-a-bot), [receive a chat ID](#receive-a-chat-id), then [send a message with TypeScript](#typescript-client). If you already have a working client, jump to [Methods](#methods) or the [complete method reference](https://api.inline.chat/bot-api-reference).

## Bot API

- Version: `0.1`
- Base URL: `https://api.inline.chat`
- Method URL: `https://api.inline.chat/bot/<method>`
- [Method reference](https://api.inline.chat/bot-api-reference)
- [OpenAPI JSON](https://inline.chat/openapi.json)

## Authentication

Send the token in the `Authorization` header. The TypeScript client does this by default:

```text
Authorization: Bearer <token>
```

Token-in-path authentication is also supported for integrations that require it:

```text
https://api.inline.chat/bot<token>/<method>
```

Prefer header authentication because URLs can be retained in request logs and tracing systems. Keep tokens in your server's environment or secret store, outside source code and browser bundles. Authentication identifies the bot; it does not bypass conversation access checks.

## Receive a Chat ID

[Create a bot](/docs/creating-a-bot), set `INLINE_BOT_TOKEN`, and initialize its update queue before sending a test message:

```bash
curl -sS --max-time 15 "https://api.inline.chat/bot/getUpdates?timeout=0" \
  -H "Authorization: Bearer ${INLINE_BOT_TOKEN:?Set INLINE_BOT_TOKEN}"
```

Check for `ok: true`. An empty array is expected for a new queue. Send the bot a DM from your human Inline account, then poll:

```bash
curl -sS --max-time 40 "https://api.inline.chat/bot/getUpdates?timeout=30" \
  -H "Authorization: Bearer ${INLINE_BOT_TOKEN:?Set INLINE_BOT_TOKEN}"
```

Find the message in the response's `result` array and use its `message.chat.chat_id` as `INLINE_CHAT_ID`. This is the conversation ID, including for a DM. The message's `from.id` identifies the sender and is a different kind of ID.

These commands use curl and a POSIX-compatible shell. They omit `offset` so you can inspect the update without acknowledging it. Messages sent before delivery was initialized are not backfilled. For a continuous consumer, acknowledgement, or `WEBHOOK_ACTIVE` errors, follow [Receive Bot Updates](/docs/bot-updates).

## TypeScript Client

The example runs with Bun `1.4.0` and `@inline-chat/bot-client` `0.1.2-alpha.0`. This is the [prerelease package baseline](/docs/technical#versions-and-examples) used by these examples. Install it in your project:

```bash
bun add @inline-chat/bot-client@0.1.2-alpha.0
```

Install with npm:

```bash
npm install @inline-chat/bot-client@0.1.2-alpha.0
```

Set `INLINE_BOT_TOKEN` and `INLINE_CHAT_ID`. Save as `send.ts`:

```ts
import { InlineBotClient } from "@inline-chat/bot-client"

const token = process.env.INLINE_BOT_TOKEN
const chatId = process.env.INLINE_CHAT_ID
if (!token || !chatId) throw new Error("Set INLINE_BOT_TOKEN and INLINE_CHAT_ID")

const bot = new InlineBotClient({ token })
const me = await bot.getMe({ signal: AbortSignal.timeout(15_000) })
if (!me.ok) throw new Error(`${me.error_code}: ${me.description}`)

const sent = await bot.sendMessage(
  { chat_id: chatId, text: "Hello from my bot" },
  { signal: AbortSignal.timeout(15_000) },
)
if (!sent.ok) throw new Error(`${sent.error_code}: ${sent.description}`)
console.log(`Sent message ${sent.result.message.message_id}`)
```

Each run creates a new message. Run it once:

```bash
bun run send.ts
```

Verify that the printed message ID corresponds to the new message in the intended Inline conversation. `getMe` checks authentication before the send; it does not check access to the destination.

The client returns API failures as `ok: false` envelopes. Network failures and aborted requests reject the promise. The example exits on either failure and does not retry. If a send times out after reaching Inline, inspect the conversation before running it again; the message may already exist.

## Methods

| Task | Common methods |
| --- | --- |
| Identify the bot or read conversations | `getMe`, `getChat`, `getChatHistory`, `getMessages`, `searchMessages` |
| Create threads and manage participants | `createThread`, `createReplyThread`, `addThreadParticipant`, `removeThreadParticipant` |
| Send or change messages | `sendMessage`, `editMessageText`, `deleteMessage`, `forwardMessage`, `sendReaction` |
| Upload or retrieve files | `uploadFile`, `getFile` |
| Configure and receive events | `getUpdates`, `setWebhook`, `deleteWebhook`, `getWebhookInfo` |

For methods that accept a destination, use exactly one of `chat_id` or `user_id`. `chat_id` identifies a conversation; `user_id` addresses a DM with that person. Legacy `peer_thread_id` and `peer_user_id` are accepted. Look up per-method fields and limits in the [method reference](https://api.inline.chat/bot-api-reference).

## Threads and Mentions

To create a private thread instead of sending to an existing chat, keep the import, token check, and `bot` construction from `send.ts`. Replace the `getMe` and send calls with the following block. Set `INLINE_USER_ID` to the intended participant's user ID, such as `message.from.id` from the incoming DM:

```ts
const userId = Number(process.env.INLINE_USER_ID)
if (!Number.isSafeInteger(userId) || userId <= 0) {
  throw new Error("Set INLINE_USER_ID to a positive user ID")
}
const created = await bot.createThread(
  { title: "Support", is_public: false, participants: [userId] },
  { signal: AbortSignal.timeout(15_000) },
)
if (!created.ok) throw new Error(`${created.error_code}: ${created.description}`)
console.log(`Created thread ${created.result.chat.chat_id}`)

const reply = await bot.sendMessage(
  {
    chat_id: created.result.chat.chat_id,
    text: `Hello [there](inline://user/${userId})`,
  },
  { signal: AbortSignal.timeout(15_000) },
)
if (!reply.ok) throw new Error(`${reply.error_code}: ${reply.description}`)
console.log(`Sent message ${reply.result.message.message_id}`)
```

Inline adds the authenticated bot to the private thread. Verify that the new thread contains the intended participant and that the greeting mentions that person. If the greeting fails, the created thread remains; use the printed chat ID to investigate or send into it instead of creating another thread.

Public threads require a space and no explicit participant list. Set `is_public: false` when creating a private thread in a space; supplying `space_id` otherwise defaults to public. A bot that can manage a thread can change its participants, but it cannot remove itself.

`sendMessage` and `editMessageText` parse [Inline Markdown](https://github.com/inline-chat/inline/blob/main/packages/protocol/docs/markdown.md) by default. A resolved `inline://user/{userId}` link produces a structured mention. Set `parse_markdown: false` to preserve the supplied syntax literally. Returned messages contain plain `text` and UTF-16 `entities`; structural content also uses `rich_message.blocks`.

## Updates

Polling and webhooks consume the same queue. Setting a webhook disables polling. These bounds apply to queued delivery:

| Limit or contract | Value |
| --- | --- |
| Retention | Up to 24 hours. |
| Delivery | At least once while updates remain available; deduplicate by bot identity and `update_id`. |
| Batch | 1–100 updates. |
| Queue capacity | 100,000 updates and 128 MiB of payload per bot. |
| Update payload | At most 512 KiB. |
| Poll response | About 4 MiB maximum. |
| Polling concurrency | One active long poll per bot. |
| Webhook secret header | `x-inline-bot-api-secret-token`. |

For initialization, acknowledgement, selection, and recovery, follow [Receive Bot Updates](/docs/bot-updates).

## Files and Access

`getFile` and `file_id` reuse require a bot-owned upload or an accessible message. Knowing a file ID alone does not grant access. Keep authorization failures distinct from missing or malformed IDs when diagnosing requests.

Message delivery depends on conversation access and [update selection](/docs/bot-updates#update-selection). Another bot's message requires an explicit resolved mention to activate delivery, even with the `all` trigger. Your integration must not rely on its own outgoing messages being echoed back as incoming updates.

## Responses

Every successful API response uses an envelope with `ok: true` and a method-specific `result`. For example, methods with no result fields can return:

```json
{ "ok": true, "result": {} }
```

An API error has `ok: false`, a numeric `error_code`, and a `description`:

```json
{ "ok": false, "error_code": 400, "description": "Invalid arguments was provided" }
```

Check `ok` before reading `result`. The TypeScript client does not retry automatically and the Bot API does not expose a send idempotency key.

| Failure | Recovery |
| --- | --- |
| Authentication error | Verify the token with `getMe` and update the configured credential. |
| Invalid request or inaccessible destination | Correct the fields or the bot's access before retrying. |
| Failed read request | Retry when appropriate for the failure. A poll carrying an offset also acknowledges earlier updates; retain your saved offset. |
| Lost response to a mutation | Check the resulting state before retrying. A timeout does not prove that a send, edit, or thread creation failed. |

## Packages

- `@inline-chat/bot-client`: client and generated types.
- `@inline-chat/bot-api-types`: generated request, response, entity, and method types.

Use the [generated method reference](https://api.inline.chat/bot-api-reference) for exact contracts and the [update guide](/docs/bot-updates) when adding a durable consumer.
