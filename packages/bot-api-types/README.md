# Inline Bot API types

Public TypeScript contract for Inline's Bot HTTP API, including messages, user and thread chats, files, actions, ordered updates, and webhooks.

Messages always carry `peer_id: { user_id } | { chat_id }`. Ordinary text uses the existing plain `text` field plus Telegram-aligned UTF-16 entities; structural messages expose renderer-neutral recursive rich text in `rich_message.blocks`. [Inline Markdown](../../docs/markdown.md) is a bounded input convenience on `sendMessage` and `editMessageText`, not a separate output field. Both parse it by default; `parse_markdown: false` preserves the supplied syntax literally.

Most integrations should install `@inline-chat/bot-client`, which re-exports these types and includes the HTTP client. Install this package directly when only the wire types are needed.

See the [Bot API guide](https://inline.chat/docs/bot-api) and [generated API reference](https://api.inline.chat/bot-api-reference).
