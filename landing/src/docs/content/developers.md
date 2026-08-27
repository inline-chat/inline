---
title: "Developers"
description: "Overview of Inline developer surfaces."
---

Inline exposes two application APIs plus a hosted MCP integration.

## Surfaces

| Surface | Use for | Transport |
| --- | --- | --- |
| [Bot API](/docs/bot-api) | Bots, alerts, serverless functions, and webhooks | HTTP |
| [Realtime API](/docs/realtime-api) | Connected clients, live state, and richer two-way integrations | WebSocket RPC |
| [MCP](/docs/mcp) | Agent access to user-approved Inline context | Streamable HTTP and OAuth |

## SDKs

| Package | Use |
| --- | --- |
| `@inline-chat/bot-client` | Typed Bot API client and generated types |
| `@inline-chat/realtime-sdk` | Realtime TypeScript client for Bun, Node.js, and JavaScript runtimes |
| `inline-sdk` | Low-level Rust API, uploads, and realtime RPC |
| `inline-client` | Stateful Rust client with local cache and sync |

[Bot API setup](/docs/bot-api) · [Realtime setup](/docs/realtime-api) · [Rust setup](/docs/rust-sdk)

## Matrix and Beeper

The official [Matrix bridge](https://github.com/inline-chat/matrix-inline) supports Beeper and self-hosted Matrix deployments through mautrix-go bridgev2.

## Deep Links

```text
inline://user/{userId}
inline://chat/{chatId}
inline://chat/{chatId}/message/{messageId}
```

## Links

- [Source and packages](https://github.com/inline-chat/inline)
- [Technical documentation](/docs/technical)
- [Create a bot](/docs/creating-a-bot)
- [OpenClaw](/docs/openclaw)
