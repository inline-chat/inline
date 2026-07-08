# Developers

Inline currently exposes two API entry points.

## Bot HTTP API

- Best for simpler bot workflows and alerts.
- Request/response over HTTP.
- Good fit for lightweight automations.

## Full Realtime API

- Best for full two-way interactions and richer bot behavior.
- WebSocket RPC with live state sync.
- Recommended when your bot behaves like an active participant in chats.

See: [Realtime API](/docs/realtime-api)

## SDKs

- TypeScript SDK: use `@inline-chat/realtime-sdk` for Bun, Node.js, and JavaScript runtimes.
- Rust SDK: use `inline-sdk` for Rust agents, bridges, CLIs, and cross-platform client foundations.

See: [Rust SDK](/docs/rust-sdk)

## Matrix and Beeper

Inline has an official Matrix bridge for Beeper and self-hosted Matrix deployments.
It is built on mautrix-go bridgev2 and can run alongside other Matrix application
service bridges.

Bridge repository: [inline-chat/matrix-inline](https://github.com/inline-chat/matrix-inline)

## Quick Start

- Method reference: [Bot API](/docs/bot-api)
- OpenClaw integration: [OpenClaw](/docs/openclaw)
- Bot token guide: [Creating a Bot](/docs/creating-a-bot)

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
