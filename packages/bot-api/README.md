# Inline Bot API client

Typed HTTP client for serverless Inline bots and agent adapters. It supports contextual reads, threads, files, message actions, polling, and webhooks without a durable WebSocket process.

```ts
import { InlineBotApiClient } from "@inline-chat/bot-api"

const bot = new InlineBotApiClient({ token: process.env.INLINE_BOT_TOKEN! })

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
