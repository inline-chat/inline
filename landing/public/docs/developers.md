# Developers

Source: https://inline.chat/docs/developers

Inline currently exposes two API entry points.

## Bot HTTP API

- Best for simpler bot workflows and alerts.
- Request/response over HTTP.
- Good fit for lightweight automations.

## Full Realtime API

- Best for full two-way interactions and richer bot behavior.
- WebSocket RPC with live state sync.
- Recommended when your bot behaves like an active participant in chats.

See: [Realtime API](https://inline.chat/docs/realtime-api)

## Quick Start

- Method reference: [Bot API](https://inline.chat/docs/bot-api)
- OpenClaw integration: [OpenClaw](https://inline.chat/docs/openclaw)
- Bot token guide: [Creating a Bot](https://inline.chat/docs/creating-a-bot)

## Deep Links

Supported deep links on native apps:

```text
inline://user/{userId}
inline://chat/{chatId}
inline://chat/{chatId}/message/{messageId}
```

## Repository

Inline publishes public protocol definitions, SDK packages, bot tools, MCP, CLI, and plugins on GitHub.

Start here: [inline-chat/inline on GitHub](https://github.com/inline-chat/inline)  
More setup and architecture details are in the README.
