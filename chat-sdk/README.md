# Inline adapter for Chat SDK

`@inline-chat/chat-sdk` connects [Vercel Chat SDK](https://chat-sdk.dev/) to the
[Inline Bot API](https://inline.chat/docs/bot-api). Requires Node.js 20+ or Bun and
Chat SDK 4.40+. This package is unreleased; the installation commands below apply
once it is published. Development is isolated to this folder and uses published dependencies.

```sh
bun add @inline-chat/chat-sdk chat @chat-adapter/state-redis
```

```ts
import { Chat } from "chat"
import { createRedisState } from "@chat-adapter/state-redis"
import { createInlineAdapter } from "@inline-chat/chat-sdk"

export const inline = createInlineAdapter({
  token: process.env.INLINE_BOT_TOKEN!,
  webhookSecret: process.env.INLINE_WEBHOOK_SECRET!,
})

export const bot = new Chat({
  userName: "helper",
  adapters: { inline },
  state: createRedisState(), // configure REDIS_URL in your deployment
  // Inline retries failed deliveries; extend Chat SDK's default 10-minute dedupe window.
  dedupeTtlMs: 7 * 24 * 60 * 60 * 1000,
})

bot.onNewMention(async (thread) => {
  await thread.subscribe()
  await thread.post("I'm listening.")
})
bot.onSubscribedMessage(async (thread, message) => {
  await thread.post(`You said: ${message.text}`)
})
bot.onDirectMessage(async (thread, message) => {
  await thread.post(`You said: ${message.text}`)
})
```

Use a durable shared state adapter in production. Each bot should have its own
state namespace. Memory state is suitable for local tests, not multiple replicas.

## Webhook endpoint and registration

For a Next.js deployment on Vercel, expose `app/api/webhooks/inline/route.ts`:

```ts
import { waitUntil } from "@vercel/functions"
import { bot } from "../../../../lib/bot"

export async function POST(request: Request) {
  return bot.webhooks.inline(request, { waitUntil })
}
```

Install `@vercel/functions` for this example. Other hosts can forward a standard
`Request` to `bot.webhooks.inline`. Supply the host's `waitUntil` equivalent so work
continues after the response. Without it, the handler awaits processing; Inline's
webhook delivery times out after 10 seconds, so use a durable job runner for long
work on hosts without background execution support.

Register the public HTTPS endpoint once as a deployment setup step, using the
same secret configured above:

```ts
const response = await inline.client.setWebhook({
  url: "https://your-app.example/api/webhooks/inline",
  secret_token: process.env.INLINE_WEBHOOK_SECRET!,
  message_trigger: "all",
  allowed_updates: ["message", "edited_message", "message_action", "message_reaction"],
})
if (!response.ok) throw new Error(response.description)
```

Registration changes this bot's delivery mode and endpoint; it is intentionally
not performed by `initialize()`. `message_trigger: "all"` is necessary for subscribed
followups without a fresh mention. It does not grant access to new conversations.
Reactions are opt-in and require the explicit `allowed_updates` entry.

Every request must provide the matching `x-inline-bot-api-secret-token` header.
Do not expose this secret or the bot token to browsers. The adapter authenticates
before reading the body and uses bearer-header authentication for outbound API calls.

## Features and semantics

| Capability | Support |
| --- | --- |
| Mentions, subscribed followups, DMs | Yes; outbound DMs use the explicit Inline adapter |
| Slash commands | Dedicated handlers, bot-target checks, duplicate suppression |
| Message edits and edit events | Yes |
| Send, reply, delete, typing | Yes |
| Streaming | Chat SDK post/edit fallback |
| Thread/channel history and info | Backward pages, chronological within each page |
| Reactions | Send/remove and added/removed event deltas |
| Cards | Markdown text, tables, images, fields, sections, dividers, callback buttons; link buttons become clickable Markdown links |
| Files | One outbound document per message; inbound photo/video/document/voice |
| Advanced controls, modals, scheduled messages | Unsupported |
| Multiple files and media replacement | Unsupported in 0.1; rejected before uploading |
| Forward history traversal | Unsupported |

Each Inline conversation maps to a Chat SDK thread and channel. Existing Inline
reply threads are independent conversations. `reply()` quotes an existing message
inside that conversation; it does not create a new native reply thread.

Thread IDs are `inline:chat:<chat-id>` or `inline:user:<peer-user-id>`. Message IDs
append the native message ID, e.g. `inline:chat:123:7`; this prevents Chat SDK's
cross-conversation deduplication from dropping messages. IDs are opaque: use IDs
returned by the SDK when editing, deleting, reacting, or replying. History cursors
are native message IDs and support only backward traversal. `openDM(userId)` returns
a peer reference; sending still depends on Bot API access rules.

## Version 0.1 scope

This adapter uses the existing Bot API with published `@inline-chat/bot-client`
0.1.1 and `@inline-chat/bot-api-types` 0.1.2. No server, protocol, or native-renderer
changes are required. Chat/thread discovery, multiple uploaded attachments in one
message, and attachment replacement are deferred. The adapter operates on known
conversation IDs and conversations delivered in bot updates, subject to existing
bot access rules. It does not expose a user's chat directory.

One uploaded document can accompany a Markdown message. Text edits retain existing
attachments. Incoming photo/video/document/voice attachments use `getFile` to refresh
download URLs. Existing Markdown images remain supported separately.

## Markdown

Normal strings, `{ markdown }`, and `{ ast }` enable Inline's Markdown parser.
`{ raw }` is the explicit literal-text mode. The adapter forwards Markdown source
unchanged on posts, edits, quoted replies, captions, and streaming updates. It
never trims input or downgrades it to a platform-specific Markdown dialect.

This includes **bold**, italic, underline (`<u>`), strikethrough, highlight (`==`),
inline/fenced/indented code, links, Inline mention/thread links, headings, nested
lists, checklists, quotes, dividers, tables, images, inline/display math,
`<details>` disclosures, progress summaries, and `<footer>` metadata.
See the [full Inline formatting guide](https://github.com/inline-chat/inline/blob/main/skills/inline/references/message-formatting.md)
for syntax and client-renderer compatibility limits.

```ts
await thread.post({ markdown: [
  "# Progress", "", "**Ready** — ==review needed==", "",
  "<details open>", '<summary kind="progress">Working</summary>', "",
  "- [x] Tests", "- [ ] Deploy", "", "</details>", "",
  "<footer>Prepared by the assistant</footer>",
].join("\n") })
await thread.post({ raw: "**This stays literal**" })
```

Incoming `message.formatted` now projects the Bot API's rich blocks/entities to
Chat SDK's standard Markdown AST, including headings, lists, tables, formatting,
and links. Inline-only extensions do not have native node types in Chat SDK's
standard parser. Use `messageToMarkdown(message.raw)` to reconstruct Inline syntax
when forwarding such content, rather than round-tripping it through the generic
Chat SDK AST stringifier. `message.raw.rich_message` remains the complete native tree.

```ts
import { messageToMarkdown } from "@inline-chat/chat-sdk"
await targetThread.post({ markdown: messageToMarkdown(message.raw) })
```

Reconstruction preserves supported semantic formatting, not the original source
whitespace. Images use the Bot API's available signed download URL, or alt text
when no URL exists; original remote image URLs are not exposed. Native group
mentions and unresolved thread titles retain their text labels because no public
Markdown URL encoding exists for those references. Do not use reconstruction as
an archival copy format; retain the raw Bot API message for that purpose.

Cards use Inline Markdown too. Titles/field values are escaped, while CardText
accepts Markdown. Unsupported controls throw. Editing to plain text clears old
buttons. Links render in the message body, not as a native URL-button row.

## Slash commands and DMs

Register the bot's command menu explicitly during deployment setup. This replaces
the existing menu; initialization does not change it automatically.

```ts
const result = await inline.client.setMyCommands({ commands: [
  { command: "help", description: "Show available commands" },
] })
if (!result.ok) throw new Error(result.description)

bot.onSlashCommand("/help", async (event) => {
  await event.channel.post("**Help**\n\nTell me what you need.")
})
```

Server-classified command messages (or leading `bot_command` entities) dispatch
only to command handlers, not DM/mention/subscribed-message handlers as well.
`/help@your_bot` is supported; commands addressed to another bot are ignored.
Edited command messages are edit events and do not rerun commands. Set a catch-all
`onSlashCommand` handler if your application needs an unknown-command response.

Incoming DMs use `bot.onDirectMessage`. Initiate an outgoing DM explicitly:

```ts
const dm = bot.thread(await inline.openDM("42"))
await dm.post("**Hello**")
```

Chat SDK 4.40's generic `bot.openDM(userId)` has hardcoded platform inference and
does not recognize Inline. Do not use it for Inline IDs, particularly alongside
Telegram/GitHub, which also use numeric IDs. The explicit path above is supported
and tested. Bot API access restrictions still apply. Native ephemeral responses
are unavailable; Chat SDK's opt-in DM fallback is available via the adapter.

```ts
import { Card, CardText, Actions, Button } from "chat"

await thread.post(Card({ title: "Approval", children: [
  CardText("Deploy this change?"),
  Actions([Button({ id: "approve", label: "Approve", value: "change-123" })]),
] }))

bot.onAction("approve", async (event) => {
  // Authenticate/authorize the actor for your application before any privileged action.
  await event.thread?.post(`Received approval for ${event.value}`)
})
```

Callback interactions are acknowledged before invoking the application handler.
For binary callback payloads authored outside this adapter, `event.value` preserves
the base64 string; inspect `event.raw` to distinguish it from text callback data.

Inbound attachments carry `fetchData()` and refresh their signed download URL via
`getFile` on demand. Rehydration restores downloads after Chat SDK serialization.
The bot authorization header is never sent to the signed download URL. Raw Bot API
payloads may contain signed URLs; handle raw payloads as sensitive data.

## Delivery and errors

Messages use Chat SDK's deduplication and locking. Slash commands, actions, and reactions additionally
use the configured shared state with a bot/update-ID key and a seven-day TTL.
This is duplicate suppression, not exactly-once processing. Chat SDK catches handler
errors; an HTTP 200 or a dedupe key does not prove an application side effect finished.
Use idempotency keys and durable jobs for consequential operations.

Bot API failures become `InlineApiError` with `code` and `description`. Rate limits
become Chat SDK `RateLimitError` with `retryAfterMs`. Transport errors propagate.
The adapter does not register webhooks, retry outgoing sends, or start polling on
its own. The existing typed Bot Client is exposed as `inline.client` for additional
Inline capabilities, including native reply-thread creation.

## Development

From `chat-sdk/`:

```sh
bun install --frozen-lockfile
bun run typecheck
bun run lint
bun test src
bun run build
bun pm pack
```

Tests exercise the real Chat SDK with its memory state adapter and a mock Bot API
transport. A deployed webhook round trip is a separate release acceptance check.

This folder has its own dependency lockfile and does not require sibling package
builds or changes to the root workspace. Run the commands above from `chat-sdk/`.
