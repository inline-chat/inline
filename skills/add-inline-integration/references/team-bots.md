# Team bots, notifiers, and internal plugins

For a team that owns a Slack, Telegram, or Discord bot and wants it in Inline too. Keep the business operation behind each handler and add Inline input and output beside the existing platform, in the bot's existing style.

| Existing | Inline version |
| --- | --- |
| Outbound notifications | One `sendMessage` per configured `chat_id`, rendered as Markdown. No inbound delivery needed. |
| Code posting to a Slack incoming webhook | Add an Inline send next to it. `setWebhook` delivers events from Inline to you; it does not accept Slack payloads. |
| Mention or DM bot | Polling loop or webhook from the [adapter guide](adapter.md) calling the same handler. The default `mentions` trigger already filters to DMs, mentions, and replies. |
| Slash command | `setMyCommands` once; handle messages with `activation_reason: "command"`. The command text is visible to the chat, so take sensitive arguments by DM. |
| Approval or button workflow | `actions` on the message, `message_action`, `answerMessageAction`, then the same approval logic against `actor.id`. |
| Modal or form | Buttons, a short DM exchange, or a link to an existing web form. |
| Reply only the caller sees | Send it by DM (`user_id`). |
| Third-party tool with only a "Slack webhook URL" setting | A small relay you run that accepts the tool's payload and calls `sendMessage`. A tool that hardcodes Slack needs its vendor to change. |

## Sending

```ts
import { InlineBotClient } from "@inline-chat/bot-client"

const inline = process.env.INLINE_BOT_TOKEN
  ? new InlineBotClient({ token: process.env.INLINE_BOT_TOKEN })
  : undefined

export async function notifyInline(chatId: string, markdown: string) {
  if (!inline) return
  const sent = await inline.sendMessage({ chat_id: chatId, text: markdown })
  if (!sent.ok) throw new Error(`inline ${sent.error_code}: ${sent.description}`)
  return sent.result.message.message_id
}
```

In any language:

```bash
curl -sS https://api.inline.chat/bot/sendMessage \
  -H "Authorization: Bearer $INLINE_BOT_TOKEN" -H "Content-Type: application/json" \
  -d '{"chat_id": 123, "text": "**Deploy finished** for `api`"}'
```

API failures come back as `ok: false`, not thrown errors. A timed-out send may have been delivered, so do not wrap sends in an automatic retry.

## Chat IDs and people

The bot must be in the chat. Add it by username, then read `chat.chat_id` from the first update it receives there. Store the ID next to the bot's Slack channel IDs.

Slack and Inline user IDs are unrelated. If the bot needs to know two accounts are the same person, keep an explicit mapping; do not match on names.

## Rendering

Convert the content, not the Block Kit JSON: headers to headings, sections to paragraphs, fields to a table or list, buttons to `actions`, link buttons to Markdown links. `<url|label>` becomes `[label](url)`, and `<@U…>` becomes `[Name](inline://user/<id>)` when the Inline user ID is known.
