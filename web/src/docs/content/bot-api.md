# Bot API

Inline Bot API is a simple HTTP API for bot integrations.
It is intended for simpler bot workflows and alerts.

## Status

Alpha. Endpoints may change.

## Base URL

- [Inline API](https://api.inline.chat)

## Authentication

Use either:

1. Header auth (recommended): `Authorization: Bearer <token>`
2. Token in path: `/bot<token>/<method>`

## Common Methods

- `GET /bot/getMe`
- `GET /bot/getChat`
- `GET /bot/getChatHistory`
- `POST /bot/sendMessage`
- `POST /bot/editMessageText`
- `POST /bot/deleteMessage`
- `POST /bot/sendReaction`

## Targeting Chats

- Use exactly one target per request: `chat_id` or `user_id`.
- For compatibility in alpha, `peer_thread_id` and `peer_user_id` are still accepted.

## When To Use This API

- Use Bot HTTP API for simpler workflows and alerts.
- For full two-way bot interactions, we recommend the Full Realtime API (`@inline-chat/realtime-sdk`).

## Quick Example

```bash
curl -sS \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -X POST "https://api.inline.chat/bot/sendMessage" \
  -d '{"chat_id":42,"text":"hello"}'
```

## Response Format

Success:

```json
{ "ok": true, "result": {} }
```

Error:

```json
{ "ok": false, "error_code": 400, "description": "Invalid arguments was provided" }
```

## SDK and Reference

- SDK package: `@inline-chat/bot-api`
- [Developers overview](/docs/developers)
- [Realtime API](/docs/realtime-api)
- [API reference UI](https://api.inline.chat/bot-api-reference)
