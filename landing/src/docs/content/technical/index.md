---
title: "Technical Documentation"
description: "Protocols, schemas, sync, files, and security references for Inline integrations."
---

Wire contracts, implementation references, and integration boundaries.

## Topics

- [Protocol](/docs/technical/protocol) — MTProto 2.0 basis, cryptographic records, authorization keys, carrier, and source.
- [Realtime](/docs/technical/realtime) — V3 application RPCs, endpoints, SDK entry points, outcomes, and V2 compatibility.
- [RPC semantics](/docs/technical/rpc) — retry policy, stable operation identities, cancellation, and uncertain commits.
- [Sync](/docs/technical/sync) — updates, cursors, catch-up, snapshots, and history gaps.
- [Files](/docs/technical/files) — native resumable uploads, file identity, authorization, and recovery.
- [Schema](/docs/technical/schema) — Bot API OpenAPI and Realtime Protocol Buffers.
- [Security](/docs/technical/security) — layered transport, trust roots, authorization, and device database encryption.
- [Local agents](/docs/technical/local-agents) — process ownership, workspace selection, and operator authorization.

## Primary References

- [Inline Protocol v1 specification](https://github.com/inline-chat/inline/blob/main/packages/protocol/docs/realtime-v3.md)
- [Realtime V3 RPC semantics](https://github.com/inline-chat/inline/blob/main/packages/protocol/docs/realtime-v3-rpc-semantics.md)
- [Inline Schema (`core.proto`)](https://github.com/inline-chat/inline/blob/main/proto/core.proto)
- [Bot API reference](https://api.inline.chat/bot-api-reference)
- [TypeScript Realtime SDK](https://github.com/inline-chat/inline/tree/main/sdk)
- [Rust SDK and client](https://github.com/inline-chat/inline/tree/main/crates)

Setup: [CLI](/docs/cli) · [MCP](/docs/mcp) · [Agents](/docs/agents) · [OpenClaw](/docs/openclaw) · [Hermes](/docs/hermes)
