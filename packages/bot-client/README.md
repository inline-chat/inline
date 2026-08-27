# Inline Bot Client

Typed HTTP client for serverless Inline bots and agent adapters. It supports contextual reads, search, normal and reply threads, files, message actions, polling, and webhooks without a durable WebSocket process.

```ts
import { InlineBotClient } from "@inline-chat/bot-client"

const bot = new InlineBotClient({ token: process.env.INLINE_BOT_TOKEN! })

const history = await bot.getChatHistory({ chat_id: 42, limit: 50 })
if (history.ok) {
  const mentionedUserIds = history.result.messages.flatMap((message) =>
    message.entities?.flatMap((entity) =>
      entity.type === "text_mention" && entity.user ? [entity.user.id] : [],
    ) ?? [],
  )
  await bot.sendMessage({ chat_id: 42, text: `I read ${history.result.messages.length} messages.` })
}

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
  await bot.addThreadParticipant({ chat_id: chatId, user_id: teammateId })
}

await bot.setWebhook({
  url: "https://agent.example.com/inline",
  secret_token: process.env.INLINE_WEBHOOK_SECRET, // optional, recommended
  message_trigger: "mentions",
})
```

`createThread` accepts `title`, `emoji`, `space_id`, `is_public`, and `participants`. Inline automatically adds the authenticated bot to private threads. Public threads do not accept an explicit participant list. Resolved Markdown user links become structured mentions. Participant changes remain separate calls; a bot may add or remove users when it can manage the thread, but it cannot remove itself.

`sendMessage` and `editMessageText` parse [Inline's bounded Markdown surface](../../docs/markdown.md) by default; set `parse_markdown: false` to preserve the supplied syntax literally. Supported blocks include headings, lists/checklists, quotes, tables, separators, fenced code, HTTP(S) images, and Inline's documented disclosure/footer extensions. Unsupported or ambiguous incomplete syntax remains text; during streaming edits, an open full-line code fence is code through the current snapshot's end. Ordinary messages return plain `text` plus Telegram-aligned UTF-16 `entities`, so mentions are safe to detect without parsing text. Structural messages also return `rich_message.blocks`, whose text-bearing blocks contain recursive rich text. Every message has `peer_id: { user_id } | { chat_id }`; expanded `chat` data is optional and omitted from repeated history and nested replies.

Use `editMessageActions` to replace actions without changing text (`actions: []` clears them). `forwardMessages` and `deleteMessages` accept 1–100 IDs and skip missing IDs. `setThreadTitle` can update `title`, `emoji`, or both.

Polling uses the same ordered backlog and is mutually exclusive with an enabled webhook:

```ts
const updates = await bot.getUpdates({ timeout: 30 })
if (updates.ok && updates.result.length > 0) {
  const last = updates.result.at(-1)!
  // Process idempotently, then acknowledge on the next request.
  await bot.getUpdates({ offset: last.update_id + 1, timeout: 30 })
}
```

The client intentionally does not retry requests. A retry of `sendMessage`, `editMessageText`, or another mutation can duplicate work because the Bot API has no idempotency key. Retry reads when appropriate, and make polling/webhook processing idempotent around `update_id`.

Bots never receive their own messages. Under `mentions`, human DMs, mentions, replies, and targeted commands activate the bot. Messages from another bot require an explicit identity-resolved mention, including when the trigger is `all`.

Header authentication is the default. Telegram-style token-in-path authentication is available when adapting an existing integration:

```ts
const bot = new InlineBotClient({
  token: process.env.INLINE_BOT_TOKEN!,
  authMode: "path",
})
```

Webhook requests carry `x-inline-update-id` and `x-inline-attempt`. When `secret_token` is configured, verify `x-inline-bot-api-secret-token` before processing the body. Delivery is at least once, so use `update_id` to make handlers safe to retry.

The webhook body is the exported `BotUpdate` union and works directly in standard `Request` runtimes such as Vercel Functions:

```ts
import type { BotUpdate } from "@inline-chat/bot-client"

export async function POST(request: Request) {
  if (request.headers.get("x-inline-bot-api-secret-token") !== process.env.INLINE_WEBHOOK_SECRET) {
    return new Response("Unauthorized", { status: 401 })
  }

  const update = await request.json() as BotUpdate
  // Persist update.update_id before producing side effects.
  return new Response("ok")
}
```

See the complete generated reference at https://api.inline.chat/bot-api-reference.
