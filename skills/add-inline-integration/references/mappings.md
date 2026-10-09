# Mappings

These are behavior maps. No other platform's tokens, IDs, payloads, or signatures work against Inline, and Inline does not emulate their endpoints. Check exact fields in the [method reference](https://api.inline.chat/bot-api-reference) or the installed types.

## Telegram to Inline

The closest match. Most adapter code carries over with renames.

| Telegram | Inline | Difference |
| --- | --- | --- |
| `getMe` | `getMe` | Bot is at `result.user`. |
| `getUpdates(offset, timeout, allowed_updates)` | same | Also takes `message_trigger`. One poller per bot. |
| `setWebhook(url, secret_token)` | same | Header is `x-inline-bot-api-secret-token`. Also `x-inline-update-id`, `x-inline-attempt`. |
| `update.message.chat.id` | `update.message.chat.chat_id` | `from.id` is unchanged. |
| `sendMessage(chat_id, text, parse_mode)` | `sendMessage({ chat_id \| user_id, text })` | Markdown is on by default; no `parse_mode`. Result is `result.message`. |
| `reply_parameters` / `reply_to_message_id` | `reply_to_message_id` | |
| `editMessageText`, `deleteMessage` | same | |
| `sendChatAction` | same | |
| `reply_markup.inline_keyboard` | `actions` rows | Each button needs `action_id`, `text`, `type: "callback"`, `callback_data`. |
| `callback_query` | `message_action` update | `actor`, `interaction_id`, `action.callback_data`. |
| `answerCallbackQuery(callback_query_id)` | `answerMessageAction({ interaction_id, text })` | |
| `sendDocument` / `sendPhoto` (one multipart call) | `uploadFile`, then `sendMessage` with `media: { type, file_id }` | Two steps. |
| `getFile` then download by `file_path` | `getFile` returns a signed `download_url` | URL expires; refetch by `file_id`. |
| `setMyCommands` | same | Commands arrive as messages with `activation_reason: "command"`. |
| `setMessageReaction` / `message_reaction` | `sendReaction`, `deleteReaction` / `message_reaction` | Opt in through `allowed_updates`. |
| `my_chat_member` | `bot_participation` | `status` is `added` or `removed`. Covers explicit adds and removes only; see the adapter guide. |
| Privacy mode | `message_trigger: "mentions" \| "all"` | Set by API, not in a settings bot. |
| Forum topic `message_thread_id` | A reply thread's own `chat_id` | No second ID; route by chat. |
| Group vs supergroup vs private | `chat.type` is `user` or `thread` | `space_id` present when in a workspace. |
| `https://api.telegram.org/bot<token>/` | `Authorization: Bearer` | Token-in-path exists (`/bot<token>/<method>`); prefer the header. |
| Deep link `?start=payload` | No equivalent | Carry state in the host's own link instead. |
| Inline mode, payments, polls, stickers, web apps | No equivalent | Omit. |

## Slack to Inline

| Slack | Inline | Adaptation |
| --- | --- | --- |
| OAuth install, bot token per workspace | One global bot token | No token exchange or per-workspace token. Keep the host's own records of tenant, consent, and configured destinations, keyed on `space_id` and `chat_id`. |
| Request signing (HMAC) | Shared secret header | Verify `x-inline-bot-api-secret-token`. |
| Events API / Socket Mode | Webhook / `getUpdates` | No envelope, no URL verification challenge. |
| `app_mention`, `message.im`, `message.channels` | `message` update | `activation_reason` says why it arrived. |
| `auth.test` | `getMe` | |
| `chat.postMessage` | `sendMessage` | |
| `chat.postMessage` with `thread_ts` | Send to the reply thread's `chat_id` | Create it with `createReplyThread` if needed. |
| `chat.update`, `chat.delete` | `editMessageText`, `deleteMessage` | |
| `conversations.history`, `conversations.replies` | `getChatHistory` on the chat or child chat | Pages go backward with `offset_message_id`. |
| `conversations.info` | `getChat` | |
| `conversations.create`, `invite`, `kick`, `rename` | `createThread`, `addThreadParticipant`, `removeThreadParticipant`, `setThreadTitle` | Public threads take no explicit participant list. |
| `reactions.add` / `reaction_added` | `sendReaction` / `message_reaction` | Unicode emoji, not `:names:`. |
| `files.upload`, file URLs with bot token | `uploadFile` + `media`, `getFile` | |
| Block Kit sections, fields, markdown | Markdown text, tables, headings | Convert content; mrkdwn is a different dialect. |
| Block Kit buttons, `block_actions`, `ack()` | `actions`, `message_action`, `answerMessageAction` | |
| Slash command | `setMyCommands` + command message | Visible to the chat. No `response_url` or `trigger_id`. |
| `<@U123>` | `[Name](inline://user/123)` | Incoming mentions are entities. |
| `team_id`, channel ID, `ts` | `space_id`, `chat_id`, `message_id` | A message is `(chat_id, message_id)`; do not parse IDs as timestamps. |
| Assistant status, `assistant.threads.setStatus` | `sendChatAction` typing | |
| `chat.startStream` / streaming | Send then edit | |
| Incoming webhook URL | `sendMessage` from owned code | Inline cannot receive Slack webhook payloads. |

## Discord and Teams to Inline

| Concept | Discord | Teams | Inline |
| --- | --- | --- | --- |
| Workspace | Guild | Team / tenant | Space (`space_id`) |
| Conversation | Channel, thread | Channel, chat | Chat (`chat_id`) |
| Receive | Gateway socket | Bot Framework activity POST | Webhook or `getUpdates` |
| Verify | Ed25519 signature | JWT | Shared secret header |
| Send / edit | REST create/edit message | `sendActivity` / `updateActivity` | `sendMessage` / `editMessageText` |
| Buttons | Components + interactions | Adaptive Card actions | `actions` + `message_action` |
| Acknowledge press | Interaction response (3 s) | Invoke response | `answerMessageAction` |
| Commands | Application commands | Command menu / message extensions | `setMyCommands`, delivered as messages |
| Rich layout | Embeds | Adaptive Cards | Markdown |
| Private reply | Ephemeral flag | Targeted message | Not available; see below |
| Forms | Modals | Task modules / card inputs | Not available; see below |
| Install | OAuth2 bot invite | App manifest, admin consent | Add the bot by username |

## Not available yet, and what to do instead

Apply the fallback, note it in the report, and continue.

| Host feature | Fallback today |
| --- | --- |
| Ephemeral / only-visible-to-you message | DM the person, or use the `answerMessageAction` notice for a button response. Never post it to the shared chat. |
| Modal, form, select menu, text input | A short DM conversation, a set of buttons, or a link to an authenticated web form the host already has. |
| Private slash-command arguments | Have the person DM the bot, or collect on the web. |
| Native token streaming, task/status cards | Send then edit; typing indicator while working. |
| Suggested prompts, app home, pinned assistant pane | Omit, or use an ordinary message with buttons. |
| List channels, list or look up users, lookup by email | Persist chats and users from updates; configure destinations by ID. |
| User email in events | The host's own account-linking flow, keyed on the Inline user ID. |
| OAuth install, scopes, admin consent, uninstall webhook | Global bot. Keep tenant and consent records in the host; record chats from the first authorized message; use `bot_participation` as a hint; treat a refused call as loss of access. |
| Send idempotency key | Treat a timed-out send as unknown rather than failed. See delivery facts. |
| Scheduled messages, message metadata | Keep in the host's scheduler and store. |
| Message-deleted, member-joined, channel-renamed events | Not in Bot API updates. Re-read what the feature depends on when acting (`getChat` for title and metadata, `getMessages` for specific messages), or state the feature as unsupported on this transport. The Realtime API carries more event kinds for hosts that need them. |
| Multiple files in one message | Send one message per file. |
| Receiving Slack-format incoming webhooks | Change the sender to call `sendMessage`. A third-party tool that only accepts a Slack webhook URL needs a small relay you own. |
