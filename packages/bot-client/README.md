# Inline Bot Client

Typed HTTP client for serverless Inline bots and agent adapters. It supports contextual reads, search, normal and reply threads, files, message actions, polling, and webhooks without a durable WebSocket process.

```ts
import { InlineBotClient } from "@inline-chat/bot-client"

const bot = new InlineBotClient({ token: process.env.INLINE_BOT_TOKEN! })

const history = await bot.getChatHistory({ chat_id: 42, limit: 50 })
if (history.ok) {
  await bot.sendMessage({ chat_id: 42, text: `I read ${history.result.messages.length} messages.` })
}

await bot.setWebhook({
  url: "https://agent.example.com/inline",
  secret_token: process.env.INLINE_WEBHOOK_SECRET, // optional, recommended
  message_trigger: "mentions",
})
```

Polling uses the same ordered backlog and is mutually exclusive with an enabled webhook:

```ts
const updates = await bot.getUpdates({ timeout: 30 })
if (updates.ok && updates.result.length > 0) {
  const last = updates.result.at(-1)!
  // Process idempotently, then acknowledge on the next request.
  await bot.getUpdates({ offset: last.update_id + 1, timeout: 30 })
}
```

Bots never receive their own messages. Under `mentions`, human DMs, mentions, replies, and targeted commands activate the bot. Messages from another bot require an explicit identity-resolved mention, including when the trigger is `all`.

Header authentication is the default. Telegram-style token-in-path authentication is available when adapting an existing integration:

```ts
const bot = new InlineBotClient({
  token: process.env.INLINE_BOT_TOKEN!,
  authMode: "path",
})
```

Webhook requests carry `x-inline-update-id` and `x-inline-attempt`. When `secret_token` is configured, verify `x-inline-bot-api-secret-token` before processing the body. Delivery is at least once, so use `update_id` to make handlers safe to retry.

See the complete generated reference at https://api.inline.chat/bot-api-reference.
