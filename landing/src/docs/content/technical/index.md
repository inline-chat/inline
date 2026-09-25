---
title: "Technical Documentation"
description: "Implement Inline connections, state synchronization, media workflows, and integrations."
---

These pages describe the contracts needed to build Inline clients, SDK adapters, and integrations. They assume familiarity with asynchronous requests, persistent storage, and authentication. For an initial bot or agent setup, start with [Developers](/docs/developers).

Read concepts before implementing a lifecycle, then use the schema and source references to check exact fields. The HTTP Bot API, Realtime application schema, and secure transport are separate interfaces with different credentials and completion rules.

## Versions and examples

This suite documents the repository interfaces listed below. Package versions and transport versions are independent: installing a newer SDK does not turn a V2 bearer token into V3 credentials.

| Surface | Documentation baseline | Status and environment |
| --- | --- | --- |
| HTTP Bot API | API `0.1` | HTTPS; bot token; polling or webhook delivery. |
| TypeScript Bot client | `@inline-chat/bot-client` `0.1.2-alpha.0`; API types `0.1.3-alpha.0` | Prerelease package baseline; examples use Bun `1.4.0`. |
| TypeScript Realtime SDK | `@inline-chat/realtime-sdk` `0.0.19-alpha.0` | Prerelease package baseline; examples use Bun `1.4.0`. |
| Protocol package | `@inline-chat/protocol` `0.0.11-alpha.0` | Generated application types and transfer helpers; examples use Bun `1.4.0`. |
| Realtime V3 | Inline Protocol v1; application layer `3` | Current key-based transport. |
| Realtime V2 | `/realtime` | Bearer-token compatibility transport. |
| Rust and Apple implementations | Linked repository source | Source-level behavior; consult each package or app release before assuming availability in an installed build. |

Code listings are checked against these repository package versions. Local serialization examples need no credentials; network examples need the credentials and access named on their page. Algorithms labeled pseudocode specify host obligations and require integration with your storage and event handlers. These pages do not define a third-party compatibility or support-lifetime guarantee.

## Choose a Reading Path

| Your task | Read in order |
| --- | --- |
| Build an HTTP bot | [Bot API](/docs/bot-api) → [Receive Bot Updates](/docs/bot-updates) → [API Schema](/docs/technical/api-schema) |
| Establish a Realtime V3 session | [Realtime](/docs/technical/realtime) → [Authentication](/docs/technical/authentication); [Protocol](/docs/technical/protocol) only if implementing the wire transport |
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

## Learning, tasks, and lookup

| Area | About: build a mental model | Using: complete a task | Reference: inspect the contract |
| --- | --- | --- | --- |
| Connections | [Realtime](/docs/technical/realtime) | [Authentication lifecycle](/docs/technical/authentication), [SDK first send](/docs/realtime-api#v2-quick-start) | [Transport specification](/docs/technical/protocol#specification), [schema index](/docs/technical/protocol-schema) |
| Local state | [Sync](/docs/technical/sync) | [Recover a gap](/docs/technical/sync-recovery#recover-a-gap) | [RPC outcomes](/docs/technical/rpc#completion-and-errors), [protobuf declarations](/docs/technical/protocol-schema) |
| Media | [Files](/docs/technical/files) | [Upload a document](/docs/technical/uploads#upload-a-document-with-typescript) | [Upload method summary](/docs/technical/uploads#method-reference), [file ranges](/docs/technical/files#download-byte-ranges) |

The schema pages are indexes into canonical declarations and behavioral guides. They do not duplicate the complete generated API. Each feature page ends with a summary of the decisions needed to use it.

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

## Summary

Choose identity and transport first. Then establish authority, perform the operation, and verify its application result. Use the relevant recovery guide for uncertain RPC results, missing update coverage, or unfinished media; each preserves a different durable identity.
