---
title: "Developers"
description: "Choose an Inline API, SDK, or automation interface for your integration."
---

Inline exposes interfaces for bot integrations, applications that maintain live state, and tools that act through your account. Start by choosing whose identity your integration will use and how it will receive changes.

## APIs

| You want to… | Start with | Identity and connection |
| --- | --- | --- |
| Build a bot that reads and replies to messages | [Bot API](/docs/bot-api) | Bot token; HTTP requests, polling, or webhooks. |
| Build a client that receives live updates and maintains synchronized state | [Realtime API](/docs/realtime-api) | Authenticated session; persistent WebSocket connection. |
| Give an agent tools to work in selected Inline conversations | [MCP](/docs/mcp) | Your account, with OAuth consent controlling the allowed context. |
| Search, send, or automate from a terminal | [CLI](/docs/cli) | Your signed-in account; commands for interactive use and scripts. |

For a first bot integration, [create a bot](/docs/creating-a-bot), [receive a test message](/docs/bot-updates#polling), then [send a reply](/docs/bot-api#typescript-client). These steps establish identity, delivery, and an observable result before you add more behavior.

If you are connecting an existing agent, use [Set Up an Agent](/docs/agents). You do not need to implement an API client for that workflow.

## SDKs

Choose the interface before choosing its library:

| Package | Responsibility | Start here |
| --- | --- | --- |
| `@inline-chat/bot-client` | Typed HTTP Bot API calls. Your application owns update processing, persistence, and deduplication. | [Send a bot message](/docs/bot-api#typescript-client) |
| `@inline-chat/realtime-sdk` | TypeScript Realtime connection, RPCs, updates, and sync recovery. | [Realtime setup and lifecycle](/docs/realtime-api) |
| `inline-sdk` | Rust RPCs, uploads, and Realtime transport. Experimental. | [Rust SDK](/docs/rust-sdk) |
| `inline-client` | Rust stateful cache, sync cursors, and pending transactions. Experimental. | [Stateful Rust client](/docs/rust-sdk#stateful-client) |

Bot API tokens and Realtime V3 authorization keys are different credentials. Check the [Realtime version table](/docs/realtime-api#versions) before selecting an authentication flow.

## Automation

- [OpenClaw](/docs/openclaw) and [Hermes Agent](/docs/hermes): connect these agent runtimes to Inline.
- [Deep Links](/docs/technical/deep-links): open a specific Inline destination from another application.
- [AppleScript](/docs/applescript): inspect or automate Inline for Mac, including the selected conversation.
- [Matrix bridge](https://github.com/inline-chat/matrix-inline): connect Inline with Matrix.

## Reference

- [Bot API method reference](https://api.inline.chat/bot-api-reference): HTTP request and response fields.
- [Realtime schema](https://github.com/inline-chat/inline/blob/main/proto/core.proto): canonical Protocol Buffers definitions.
- [Technical documentation](/docs/technical): transport, authentication, sync, and retry contracts for client implementers.
- [Source and packages](https://github.com/inline-chat/inline): implementations and package manifests.
