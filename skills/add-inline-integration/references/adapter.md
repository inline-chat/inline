# Adapter guide

## API contract

Implement the jobs the host's channel interface asks for.

| Job | Inline call |
| --- | --- |
| Identify self | `getMe`; the bot is `result.user`. |
| Receive | `getUpdates` loop or webhook, producing the host's normalized event. |
| Send / reply | `sendMessage` with `chat_id`, or `user_id` to DM a person. `reply_to_message_id` quotes a message. |
| Edit / delete | `editMessageText`, `deleteMessage` with `chat_id` and `message_id`. |
| Show activity | `sendChatAction` with `typing`; `cancel` to clear. |
| Stream | Send once, then `editMessageText` with the growing text. |
| Buttons | `actions` rows on send or edit; `message_action` update; `answerMessageAction`. |
| History / context | `getChatHistory`, `getMessages`, `searchMessages`, `getChat`. |
| Threads | `createReplyThread` on a message; the result is a chat like any other. |
| Files | In: `message.media` and `getFile`. Out: `uploadFile`, then `sendMessage` with `media`. |
| Reactions | `sendReaction`, `deleteReaction`; `message_reaction` updates if opted in. |
| Commands | `setMyCommands`; commands arrive as messages with `activation_reason: "command"`. |

Base URL `https://api.inline.chat/bot/<method>`, header `Authorization: Bearer <token>`, JSON bodies. Every response is `{ ok: true, result }` or `{ ok: false, error_code, description }`, so check `ok` rather than HTTP status. IDs are numbers in responses and accept numbers or decimal strings in requests.

## Minimal adapter

A text-message starter: it handles `message` updates with text and skips other kinds. Replace `handleTurn` with the call into the shared agent or handler, and fit persistence, error handling, and shutdown to the host's conventions.

```ts
import { InlineBotClient, type BotUpdate } from "@inline-chat/bot-client"

type Turn = { chatId: number; userId: number; text: string; messageId: number; spaceId?: number }
declare function handleTurn(turn: Turn, reply: (text: string) => Promise<void>): Promise<void>
declare function loadOffset(): Promise<number | undefined>
declare function saveOffset(offset: number): Promise<void>

const bot = new InlineBotClient({ token: process.env.INLINE_BOT_TOKEN! })

async function onUpdate(update: BotUpdate) {
  if (!("message" in update)) return
  const m = update.message
  if (!m.text) return
  const chatId = m.chat.chat_id
  await bot.sendChatAction({ chat_id: chatId, action: "typing" })
  await handleTurn(
    { chatId, userId: m.from.id, text: m.text, messageId: m.message_id, spaceId: m.chat.space_id },
    async (text) => {
      const sent = await bot.sendMessage({ chat_id: chatId, text })
      if (!sent.ok) throw new Error(`${sent.error_code}: ${sent.description}`)
    },
  )
}

export async function run(stop: AbortSignal) {
  let offset = await loadOffset()
  while (!stop.aborted) {
    const signal = AbortSignal.any([stop, AbortSignal.timeout(35_000)])
    const res = await bot.getUpdates({ offset, timeout: 25 }, { signal }).catch((error) => {
      if (stop.aborted) return undefined
      throw error
    })
    if (!res) break
    if (!res.ok) throw new Error(`${res.error_code}: ${res.description}`)
    for (const update of res.result) {
      if (stop.aborted) return
      await onUpdate(update)
      offset = update.update_id + 1
      await saveOffset(offset)
    }
  }
}
```

Passing `offset` acknowledges every update below it, so advance it only past updates that are handled or handed to the host's queue. The request deadline must exceed the long-poll `timeout`.

The webhook form uses the same `onUpdate`:

```ts
export async function POST(request: Request) {
  if (request.headers.get("x-inline-bot-api-secret-token") !== process.env.INLINE_WEBHOOK_SECRET) {
    return new Response("unauthorized", { status: 401 })
  }
  const update = (await request.json()) as BotUpdate
  await enqueue(update) // the host's queue, keyed by bot id + update.update_id
  return new Response("ok")
}
```

Inline waits 10 seconds for a `2xx` and redelivers otherwise, so an agent turn cannot run inside the request. Register the URL once with `setWebhook({ url, secret_token, message_trigger })`. Polling and webhook share one queue and are mutually exclusive.

In another language the same thing is `GET /bot/getUpdates?offset=…&timeout=25` and `POST /bot/sendMessage` with `{"chat_id": …, "text": …}`.

## Activation

`message_trigger` is set through `getUpdates` or `setWebhook` and persists.

- `mentions` (default): DMs from people, messages that mention the bot, replies to the bot, and commands addressed to it. The server does the filtering, so no mention parsing is needed.
- `all`: every message in chats the bot can access. Needed when the host continues a thread without a fresh mention.

Each update carries `activation_reason`. Route on it instead of re-deriving why a message arrived. Mentions in text are entities with a `user`; compare `entity.user.id` to the bot's ID, never the display name.

A bot does not receive its own ordinary messages, and messages from other bots arrive only when they mention this bot.

Two exceptions apply only when the host uses Inline Agents. A thread assigned to this bot as its agent delivers people's messages without a mention, and an explicit handoff from this bot into its own agent thread in another chat is delivered although the bot is the author. In that case keep `activation_reason` and `activated_agent` with the turn, and do not filter on "author is me" first. The Chat SDK adapter skips self-authored messages, so handoffs do not pass through it.

Reactions are off by default. Pass `allowed_updates` including `message_reaction` together with the other kinds needed, because the list replaces the previous selection.

## Formatting

`text` is parsed as Inline Markdown by default: emphasis, code, fenced code, links, headings, lists, checklists, quotes, tables, images. Model output can usually be sent unchanged; do not convert it to Slack mrkdwn or Telegram MarkdownV2. Pass `parse_markdown: false` for literal text. Mention a person with `[Name](inline://user/<id>)`.

## Streaming

There is no streaming primitive. Send the first chunk, keep its `message_id`, and edit with the full text so far, reusing the host's edit-based streamer if it has one. Inline publishes no edit rate limit; about one edit per second is a safe default. Check the envelope of the final edit, because a failed last edit leaves a truncated answer. An unterminated code fence renders as code to the end of the text, so partial snapshots look right.

## Buttons

```ts
await bot.sendMessage({
  chat_id,
  text: "Deploy `api` to production?",
  actions: [[
    { action_id: "approve", text: "Approve", type: "callback", callback_data: approvalId },
    { action_id: "deny", text: "Deny", type: "callback", callback_data: approvalId },
  ]],
})
```

A press arrives as a `message_action` update with `actor`, `chat`, `message_id`, `interaction_id`, and `action`. Call `answerMessageAction({ interaction_id, text })`; the optional text shows as a brief notice to the person who pressed. Authorize against `actor.id` with the host's existing checks.

To remove buttons, pass an empty list: `editMessageText({ chat_id, message_id, text, actions: [] })` or `editMessageActions({ chat_id, message_id, actions: [] })`. An edit that omits `actions` keeps them, and they stay pressable.

Only buttons exist. Selects, text inputs, and modals have no equivalent. A link button is a Markdown link in the text.

## Threads and sessions

Key sessions on `chat_id`. That is correct for DMs, top-level threads, and reply threads, because each is its own chat. A reply thread's `chat.parent_chat_id` and `chat.parent_message` give the parent for context.

If the host answers channel mentions in a thread (Slack style), call `createReplyThread({ chat_id, message_id })` on the triggering message and send into the returned `chat.chat_id`; a message's existing thread is returned if it has one. If the host answers in place (Telegram style), send to the same chat.

A reply thread inherits its parent's audience. Listing fewer participants does not hide it from people who can see the parent. For a restricted audience use a DM or `createThread` with `is_public: false`.

## Files

Incoming `message.media` has a `file` with `file_id` and usually a signed `download_url` that expires. Store the `file_id` and call `getFile` for a fresh URL later. Treat the URL as a secret.

Outgoing: `uploadFile` (multipart) returns a `file_id`; attach it with `sendMessage({ chat_id, text, media: { type: "document", file_id } })`. One uploaded file per message.

## Chats, access, and identity

There is no method to list the bot's chats or search for people. Record what the host needs as updates arrive:

- Every message update carries the full `chat` (title, `space_id`, type) and `from` (ID, username, names). DMs may have no `space_id`.
- `bot_participation` arrives when the bot is explicitly added to or removed from a chat. Treat it as a hint. Access can also come from space membership, a public thread, or a parent chat, none of which produce an event, so a `removed` event does not prove access is gone and access can end without one.
- For a known chat and person, `getChat`, `getSpace`, and `getChatParticipant` (including the person's space role) are available. A refused call is the authoritative sign that access is gone.

For proactive sends use stored `chat_id`s, or `user_id` to DM someone. A DM can be refused when the person has not interacted with the bot.

To connect an Inline sender to a host account, use the host's existing linking flow from another platform, started from the sender's Inline user ID. Inline provides no email and no sign-in for bots. When the request came from a shared chat, send the link by DM.

For a bring-your-own bot, `getMe` returns the bot's profile and nothing about its creator. Bind the owner's Inline user ID to the connection before running turns with the owner's credentials, using whatever the host does elsewhere (a pairing code sent to the bot, an allowlist of user IDs, or the linking flow). Other senders stay unlinked unless the owner shares access explicitly.
