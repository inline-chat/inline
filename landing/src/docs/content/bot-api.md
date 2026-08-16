# Bot API

Inline Bot API is an HTTP API for bots, serverless agents, and workflow runtimes that cannot keep a WebSocket process alive. It provides contextual reads, search, threads, files, actions, polling, and webhooks over the same bot identity used by Inline.

## Compatibility

The current public contract is `0.1`. Pin the generated packages and review the changelog when upgrading.

## Base URL

- [Inline API](https://api.inline.chat)

## Authentication

Use either:

1. Header auth (recommended): `Authorization: Bearer <token>`
2. Token in path: `/bot<token>/<method>`

The client uses header authentication by default. Token-in-path mode exists for Telegram-style adapters.

## TypeScript Client

```sh
npm install @inline-chat/bot-client@^0.1.0
```

```ts
import { InlineBotClient } from "@inline-chat/bot-client"

const bot = new InlineBotClient({ token: process.env.INLINE_BOT_TOKEN! })
const history = await bot.getChatHistory({ chat_id: 42, limit: 50 })

if (history.ok) {
  await bot.sendMessage({ chat_id: 42, text: `Read ${history.result.messages.length} messages.` })
}
```

Use `authMode: "path"` only when adapting a client that expects the token in the URL.

## Core Methods

- `GET /bot/getMe`
- `GET /bot/getChat`
- `GET /bot/getChatHistory`
- `POST /bot/getMessages`
- `POST /bot/searchMessages`
- `POST /bot/createThread`
- `POST /bot/createReplyThread`
- `POST /bot/sendMessage`
- `POST /bot/editMessageText`
- `POST /bot/deleteMessage`
- `POST /bot/forwardMessage`
- `POST /bot/sendReaction`
- `POST /bot/uploadFile`
- `GET /bot/getUpdates`
- `POST /bot/setWebhook`

Chats have `type: "user" | "thread"`. A reply thread may contain `parent_chat_id` and `parent_message`. The embedded parent is a normal message encoded once; its chat does not recursively include another parent message.

## Targeting Chats

- Use exactly one target per request: `chat_id` or `user_id`.
- Legacy `peer_thread_id` and `peer_user_id` targets are also accepted.

## Receiving Updates

Use either long polling or a webhook for one ordered, durable update stream. Enabling a webhook disables polling until `deleteWebhook` is called.

```ts
await bot.setWebhook({
  url: "https://agent.example.com/inline",
  secret_token: process.env.INLINE_WEBHOOK_SECRET,
  message_trigger: "mentions",
})
```

The secret is optional. When set, verify the `x-inline-bot-api-secret-token` request header. Webhooks also include `x-inline-update-id` and `x-inline-attempt`. Delivery is at least once; use `update_id` to make processing safe to retry.

Bots never receive their own messages. With the default `mentions` trigger, humans activate a bot through user chats, resolved mentions, replies, commands, and message actions. Other bots activate it only through an explicit resolved mention.

Use the Bot HTTP API for serverless agents and ordinary request/response integrations. Use the Realtime API when a continuously connected process needs live client state beyond the Bot contract.

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

## SDK and Reference

- Client package: `@inline-chat/bot-client`
- Types package: `@inline-chat/bot-api-types`
- [Developers overview](/docs/developers)
- [Realtime API](/docs/realtime-api)
- [API reference UI](https://api.inline.chat/bot-api-reference)
