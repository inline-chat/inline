---
name: add-inline-integration
description: Add Inline (inline.chat) as a messaging channel to an agent harness, assistant product, or bot that already supports Slack, Telegram, Discord, or Teams. Use when implementing an Inline adapter/gateway/surface, extending a team bot or notifier to post in Inline, or porting Slack or Telegram bot code to Inline's Bot API.
---

# Add Inline Integration

You are working in the codebase of a product that already talks to at least one chat platform. The goal is a working Inline channel next to the existing ones, reusing the host's agent, tools, sessions, and jobs. Existing platforms keep working unchanged unless the user asks for a replacement.

Inline behaves like other chat platforms in most respects. Where it does, follow the host's existing adapter patterns, conventions, and reliability standards; this skill does not restate them. It covers what Inline does differently and the API facts needed to build against it.

Most of the integration can be built in one pass with what Inline ships today. A few platform features have no Inline equivalent yet; each has a fallback in [mappings](references/mappings.md). Apply it, list it in the report, and keep going. Stop to ask only when a fallback would change who can see something.

## How Inline bots differ

- **A bot is a global identity with one token.** There is no per-workspace OAuth install and no token exchange. A product can run one shared bot such as `@yourproductbot` that people DM or add to their spaces and threads, or let each user connect a bot they created by pasting its token, or both. Follow the model the host uses for Telegram if it has one; otherwise ask.
- **The Bot API is Telegram-shaped.** `getMe`, `getUpdates`, `setWebhook`, `sendMessage`, `editMessageText`, `{ ok, result }` envelopes, UTF-16 entities, a secret-token webhook header. If the host has a Telegram adapter, that is the template to copy, even when the request says "like our Slack integration".
- **Threads are chats.** A reply thread is its own conversation with its own `chat_id` and a pointer to its parent. Quoting a message in the same chat (`reply_to_message_id`) and opening a child thread (`createReplyThread`) are different operations.
- **Message IDs are per chat.** A message is `(chat_id, message_id)`. Include the platform and bot ID in session, lock, and dedupe keys.
- **Everything in a chat is visible to the chat.** There are no ephemeral messages, and a command is an ordinary message. Anything the host would show to one person goes by DM or is dropped; it is never posted to the shared chat as a fallback.
- **A token identifies a bot, not a person.** The bot sees each sender's Inline user ID, username, and name, and no email. An Inline sender gets another identity's credentials, memory, or entitlements only after the host's own linking or pairing step. This includes the owner of a bring-your-own bot, since anyone can message it.
- **Sends have no idempotency key.** A timed-out send may have been delivered.

## Workflow

1. **Find the channel boundary.** Locate where platforms are registered and the interface an adapter implements. Trace one inbound message through the closest existing adapter to the reply, and one background send if the host has them. Platform-shaped fields also hide in shared types, persistence, and prompts, so do not stop at a search for the Slack import.
2. **Pick the template and transport** (below).
3. **Build the adapter** from the [adapter guide](references/adapter.md).
4. **Map the features the host actually uses** with [mappings](references/mappings.md).
5. **Check delivery** against [delivery facts](references/delivery.md) and the host's own standard for its other channels.
6. **Verify and report.**

For a multi-tenant product harness, also read [harnesses](references/harnesses.md). For a notifier, command bot, or approval workflow, read [team bots](references/team-bots.md) instead; it is a much smaller job.

## Template and transport

| Host has | Start from |
| --- | --- |
| A Telegram adapter | Copy it and rename per the Telegram table in mappings. |
| Vercel Chat SDK (`chat` package) | Register `@inline-chat/chat-sdk` beside the existing adapters. Check its peer range against the host's `chat` version first. |
| OpenClaw or Hermes | Use the maintained Inline plugin; do not write a new adapter. |
| Only Slack, Discord, or Teams | A native adapter against the host's channel interface, structured like the existing one. |
| No channel abstraction | A small provider seam at the calls the feature needs, with Inline behind it. |

| Deployment | Receive updates with |
| --- | --- |
| Public HTTPS endpoint, serverless | Webhook: `setWebhook` with a `secret_token`. |
| Worker or private network (where Slack uses Socket Mode) | Long polling: `getUpdates`. |
| Needs live client state or RPCs beyond the Bot API | `@inline-chat/realtime-sdk` with the bot token, which authenticates the V2 endpoint only. Prefer polling unless there is a concrete need. |

TypeScript hosts use `@inline-chat/bot-client`. Other languages call the HTTP API with the host's existing HTTP client. Use the package versions the docs currently name, and trust installed types over this skill where they disagree.

## Verify and report

Test the way the host tests its other adapters: an inbound update through the real adapter boundary into the shared handler and out to an Inline send, with HTTP faked. Confirm an existing platform still works and that the host starts with Inline unconfigured. Add cases for the Inline differences you relied on, such as two chats with the same message ID, an unlinked sender, and a private response routed by DM.

Live testing needs a bot token and a chat the user designates; creating the bot is a human step ([Create a bot](https://inline.chat/docs/creating-a-bot)). Without a token, finish the code and tests and say what is unverified. `setWebhook` and `setMyCommands` replace the bot's current configuration, so run them from an explicit setup step.

Report what was added, which host features are native, fallback, or omitted on Inline, the setup steps, and what was and was not verified.

## References

- [Adapter guide](references/adapter.md): API contract, minimal adapter, activation, streaming, buttons, threads, files, identity.
- [Mappings](references/mappings.md): Telegram, Slack, Discord, Teams to Inline; missing features and fallbacks.
- [Delivery facts](references/delivery.md): queue, acknowledgement, ordering, send outcomes, Chat SDK.
- [Harnesses](references/harnesses.md): shared and bring-your-own bots, tenancy, access, Chat SDK hosts.
- [Team bots](references/team-bots.md): notifiers, commands, approvals.
- Inline docs: [Bot API](https://inline.chat/docs/bot-api), [updates](https://inline.chat/docs/bot-updates), [method reference](https://api.inline.chat/bot-api-reference), [types](https://github.com/inline-chat/inline/blob/main/packages/bot-api-types/src/index.ts), [Markdown](https://github.com/inline-chat/inline/blob/main/packages/protocol/docs/markdown.md), [Realtime](https://inline.chat/docs/realtime-api).
- Working adapters: [Chat SDK](https://github.com/inline-chat/inline/tree/main/plugins/chat-sdk-plugin), [OpenClaw](https://github.com/inline-chat/inline/tree/main/plugins/openclaw), [Hermes](https://github.com/inline-chat/inline/tree/main/plugins/hermes-agent).
