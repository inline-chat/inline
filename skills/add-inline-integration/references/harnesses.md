# Agent harnesses and assistant products

For a product whose agent runtime, tools, memory, and scheduler are shared across chat platforms. Read the [adapter guide](adapter.md) first. Implement the host's channel interface the way its other adapters do; this file covers the Inline-specific parts of a product integration.

## Where Inline usually needs a change

- **Closed platform unions.** Add an `inline` variant to platform enums, destination types, schemas, and database enums. This is often the largest part of the diff.
- **Shared helpers that assume another platform.** Destination builders that parse team and channel IDs, thread context that reads Slack timestamps, identity resolution that calls another platform's user directory, agent tools that pass IDs to a specific client.
- **Session key.** Platform, bot ID, and `chat_id`. Existing keys stay as they are.
- **Platform-only UI.** Assistant panes, modals, ephemeral notices, and suggested prompts stay on their platforms; use a fallback from [mappings](mappings.md) or omit on Inline.

Check that a sender reaches execution as the right host principal, that agent tools work against Inline, and that a delayed reply still finds its destination after a restart.

## Shared bot

One token and one update stream serve every customer.

- Tenancy comes from `chat.space_id`, or the user for DMs outside a space.
- There is no install handshake, admin consent, or scopes. Keep the host's own tenant, consent, and plan records, and enforce workspace policy in the host. `getChatParticipant` returns a known person's space role when an admin check is needed.
- Record chats from the first authorized message. `bot_participation` is a hint, not an install or uninstall ledger; see the adapter guide.
- A bot can read history in every chat it can access. Load context only for the chat the turn is in.

## Bring your own bot

Each connection is a user-supplied token.

- Validate with `getMe` and store the bot ID with the connection.
- The token does not identify its owner. Pair the owner's Inline user ID before privileged work; see the adapter guide.
- A bot has exactly one update queue. Keep one consumer per bot ID across the host, even if two connections present the same bot.
- With webhooks, use a secret and URL per bot so an update is attributed before its body is trusted.
- `setWebhook` and polling take over the bot's delivery from any other program using the token.
- On disconnect, call `deleteWebhook` only if `getWebhookInfo` still shows this connection's URL. A different URL means the bot now belongs to another service. The API has no compare-and-delete, so this narrows the race without closing it.

## Vercel Chat SDK hosts

Register `createInlineAdapter({ token, webhookSecret })` from `@inline-chat/chat-sdk` in the `adapters` map and keep the existing handlers.

- Check the adapter's `chat` peer range against the installed version first. If the host is pinned below it, the upgrade is a prerequisite with its own regression pass; tell the user before doing it.
- SDK state keys use IDs like `inline:chat:<id>` without the bot. One Inline bot can share the host's state adapter. More than one needs a `Chat` instance and state namespace per bot, or two bots in the same chat suppress each other's messages.
- Generic `reply()` quotes within the chat. Use `inline.client.createReplyThread` for a native reply thread.
- Start a DM with `bot.thread(await inline.openDM(userId))`.
- Subscribed follow-ups need `message_trigger: "all"`; reactions need `message_reaction` in `allowed_updates`. Both are set in the `setWebhook` call.
- Cards render to Markdown with callback buttons. Modals, ephemeral posts, and scheduled messages are unsupported; guard those call sites by platform.
- Raise the SDK's dedupe TTL to cover Inline's 24-hour redelivery window, and read the Chat SDK section of [delivery facts](delivery.md).

## Hosts built directly on Bolt or a platform SDK

Add a sibling Inline surface that calls the same core services, with polling where the deployment relies on Socket Mode. Keep Block Kit presenters and Slack install management Slack-only. Where one Slack client interface is called from many places, a thin in-process implementation of only the methods in use, backed by Inline, can keep the first diff small.
