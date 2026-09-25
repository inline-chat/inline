---
title: "Technical Documentation"
description: "Implement Inline connections, state synchronization, media workflows, and integrations."
---

These pages describe the contracts needed to build Inline clients, SDK adapters, and integrations. They assume familiarity with asynchronous requests, persistent storage, and authentication. For an initial bot or agent setup, start with [Developers](/docs/developers).

Read concepts before implementing a lifecycle, then use the schema and source references to check exact fields. The HTTP Bot API, Realtime application schema, and secure transport are separate interfaces with different credentials and completion rules.

## Choose a Reading Path

| Your task | Read in order |
| --- | --- |
| Build an HTTP bot | [Bot API](/docs/bot-api) → [Receive Bot Updates](/docs/bot-updates) → [API Schema](/docs/technical/api-schema) |
| Establish a Realtime V3 session | [Protocol](/docs/technical/protocol) → [Realtime](/docs/technical/realtime) → [Authentication](/docs/technical/authentication) |
| Maintain a local cache | [Schema](/docs/technical/schema) → [Sync](/docs/technical/sync) → [Sync Recovery](/docs/technical/sync-recovery) |
| Send mutations safely across disconnects | [RPC Semantics](/docs/technical/rpc) → [Protocol Schema](/docs/technical/protocol-schema) |
| Upload and attach media | [Files](/docs/technical/files) → [Resumable Uploads](/docs/technical/uploads) |
| Open Inline from another app | [Deep Links](/docs/technical/deep-links) |
| Operate a coding-agent bridge | [Local Agents](/docs/technical/local-agents) → [Security](/docs/technical/security) |

## How the Interfaces Fit

| Layer | Responsibility | Does not establish |
| --- | --- | --- |
| Secure transport | Protect and authenticate client–server records. | End-to-end encryption between users. |
| Realtime RPCs | Invoke typed operations and return application results. | That a timed-out mutation did not execute. |
| Update synchronization | Apply ordered durable changes to client state. | That all historical messages have been loaded. |
| Media upload | Store and finalize a file into a typed media result. | That a message containing the media was sent. |

Those boundaries determine recovery: reconcile an uncertain mutation, repair a missing update range, and resume an upload using its existing identity. Do not treat a reconnect as proof that all three have completed.

## Topics

- [Protocol](/docs/technical/protocol)
- [Deep Links](/docs/technical/deep-links)
- [Realtime](/docs/technical/realtime)
- [Authentication](/docs/technical/authentication)
- [Realtime V2 compatibility](/docs/technical/realtime-v2)
- [RPC Semantics](/docs/technical/rpc)
- [Sync](/docs/technical/sync)
- [Sync Recovery](/docs/technical/sync-recovery)
- [Files](/docs/technical/files)
- [Resumable Uploads](/docs/technical/uploads)
- [Schema](/docs/technical/schema)
- [Security](/docs/technical/security)
- [Local Agents](/docs/technical/local-agents)

## Sources

- [`core.proto`](https://github.com/inline-chat/inline/blob/main/proto/core.proto): canonical Realtime methods, results, objects, and updates.
- [Bot API reference](https://api.inline.chat/bot-api-reference): HTTP method contracts.
- [TypeScript SDK](https://github.com/inline-chat/inline/tree/main/packages/sdk): connection, RPC, and sync implementations.
- [Rust SDK](https://github.com/inline-chat/inline/tree/main/crates/sdk) and [stateful client](https://github.com/inline-chat/inline/tree/main/crates/client): Rust transport, cache, and recovery implementations.
- [Protocol package](https://github.com/inline-chat/inline/tree/main/packages/protocol): generated schema, secure transport, and shared helpers.
