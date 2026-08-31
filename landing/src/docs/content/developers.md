---
title: "Developers"
description: "Overview of Inline developer surfaces."
---

Inline exposes two application APIs plus a hosted MCP integration.

## Surfaces

| Surface | Use for | Identity and transport |
| --- | --- | --- |
| [Bot API](/docs/bot-api) | Alerts, bot conversations, and webhook handlers | A bot token over HTTP |
| [Realtime API](/docs/realtime-api) | Connected clients, live state, and two-way integrations | Bearer-token V2 or key-authenticated V3 over WebSocket |
| [MCP](/docs/mcp) | Let an existing agent use approved Inline context | User OAuth consent over Streamable HTTP |
| [CLI](/docs/cli) | Shell scripts, chat searches, and transcript exports | The signed-in CLI account |

For a first custom integration, [create a bot](/docs/creating-a-bot), verify it with `getMe`, then [send a message](/docs/bot-api#first-message). Choose Realtime when you need a persistent connection and synchronized state.

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

Use IDs returned by the API. A message ID is scoped to its chat; keep both values when storing a message reference. Opening a link does not grant access to its target.

## Contracts and Machine-Readable Docs

- [Schema](/docs/technical/schema): OpenAPI, Protocol Buffers, ID and timestamp conventions.
- [RPC semantics](/docs/technical/rpc): retries and uncertain mutation outcomes.
- [Files](/docs/technical/files): upload and file-access rules.
- [Credential boundaries](/docs/technical/security#surface-credentials): which credentials each surface accepts.
- [Docs index](/llms.txt) and [full Markdown corpus](/llms-full.txt): the same published content for tools and agents.

## Links

- [Source and packages](https://github.com/inline-chat/inline)
- [Technical documentation](/docs/technical)
- [Create a bot](/docs/creating-a-bot)
- [OpenClaw](/docs/openclaw)
