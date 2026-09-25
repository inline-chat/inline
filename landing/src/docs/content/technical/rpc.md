---
title: "RPC Semantics"
description: "How to interpret RPC completion and recover an uncertain mutation."
---

An RPC result confirms what the server returned for one request. A timeout or lost connection does not prove a dispatched mutation failed: the server may have committed it before the result was lost. Use this page when implementing retries after reconnect.

## About this page

For callers deciding whether to repeat an interrupted request. You need an authenticated client and the method’s application identity. Read completion outcomes first, then choose a retry rule; use this page as a behavior reference beside the generated method signature.

**Applies to:** Realtime V2 and V3; TypeScript SDK. See the [version and example baseline](/docs/technical#versions-and-examples) before choosing a package.

## Completion and errors

The request message ID correlates a `RpcCall` with a `RpcResult` or `RpcError`; it is not an application idempotency key. The TypeScript SDK defaults response-waiting calls to a 30-second timeout. Canceling a wait does not undo a dispatched operation.

| Observation | What the caller knows | Next action |
| --- | --- | --- |
| Matching `RpcResult` | The method returned its result. | Apply the result; use updates to maintain local state. |
| Authenticated protobuf `RpcError` | The method returned an application error, even if its numeric `code` is 503 or 504. | Handle the method error. |
| Outer transport `rpc_error(503)` | The request was rejected before execution. | Retry when connection admission is available. |
| Outer transport `rpc_error(504)` | The commit outcome is unknown. | Reconcile or retry under a method-specific repeat-safe policy. |
| Timeout, cancellation, or disconnect after dispatch | No result was observed; the commit outcome may be unknown. | Reconcile before repeating a mutation without a stable identity. |

The TypeScript transport distinguishes outer 503/504 from protobuf application errors. Its `ProtocolClient` rejects an attempted `never-replay` call on timeout or disconnect with `commit-outcome-unknown`. A canceled promise ends the local wait; treat a mutation that may already have been sent as uncertain even if the cancellation error itself is an `AbortError`.

## Rules

1. For a read-only method, repeat the request if you still need a result. A fresh result may reflect newer state.
2. For a mutation with a documented stable operation identity, preserve the same identity and input across attempts. Repeat only when that method's server behavior and client policy permit it.
3. For a state-shaped mutation, read authoritative state first. If it already matches the intended outcome, stop.
4. For a creation method without stable operation identity, reconcile by an authoritative lookup or surface the uncertain outcome to the caller.

The TypeScript SDK selects `replay-safe` for listed reads, `CREATE_UPLOAD`, `SAVE_UPLOAD_PART`, and `SET_MY_BOT_CAPABILITIES`; it selects it for `SEND_MESSAGE` only with a nonzero `random_id`. Other methods default to `never-replay`. This is an SDK reconnect policy, not a claim that arbitrary callers can safely retry. The SDK does not mark `FINISH_UPLOAD` or `CREATE_SUBTHREAD` for automatic replay.

## Stable Identities

| Operation | Identity to retain | Recovery |
| --- | --- | --- |
| `SEND_MESSAGE` | Nonzero signed 64-bit `random_id` for the same send | Reuse the original ID and payload; reconcile the resulting message or echoed update. The TypeScript SDK generates an ID if its send wrapper is not given one. |
| `CREATE_UPLOAD` | `client_upload_id` in the account session | Reuse the same ID for the same upload creation. |
| `SAVE_UPLOAD_PART` | `upload_id` and `part_index` | Repeat only the same part bytes and hash; inspect upload state if uncertain. |
| `FINISH_UPLOAD` | Existing `upload_id` | Query upload state or canonical result before another finish attempt. It is not in the SDK's automatic replay set. |
| `CREATE_SUBTHREAD` | Parent chat and parent message | Inspect the parent's existing subthreads before creating another. There is no automatic replay policy. |

For example, a message send times out after dispatch. Keep its `random_id`, wait for a matching result or message update, and retry the same send only under the send method's idempotency contract. A new `random_id` describes a new send and can create a duplicate message.

## No Automatic Replay

Edits, deletes, participant changes, dialog preferences, profile and session changes, connector changes, upload cancellation, and dialog-folder update or deletion require authoritative reconciliation before a retry. Creation of chats, bots, spaces, groups, Grid rooms, external tasks, CLI sessions, connector OAuth flows, or dialog folders needs its own stable operation identity before a client enables automatic replay.

Connection-local serialization of selected operations preserves their order on that connection. It does not make them repeat-safe or coordinate a second connection.

## Implementation sources

- [Protocol RPC envelopes and methods](https://github.com/inline-chat/inline/blob/main/proto/core.proto) define `RpcCall`, `RpcResult`, and `RpcError`.
- [TypeScript SDK policy](https://github.com/inline-chat/inline/blob/main/packages/sdk/src/sdk/inline-sdk-client.ts) selects replay behavior by method.
- [TypeScript RPC client](https://github.com/inline-chat/inline/blob/main/packages/sdk/src/realtime/protocol-client.ts) owns timeouts, reconnects, and pending calls.

For state reconciliation after a lost update, see [Sync recovery](/docs/technical/sync-recovery).

## Summary

Classify the response before choosing a retry. Retain stable identities for repeat-safe operations and reconcile creations without one. If updates cannot establish the result, use [bucket recovery](/docs/technical/sync-recovery) before declaring the local projection current.
