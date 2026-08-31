---
title: "RPC Semantics"
description: "Replay, reconciliation, commit uncertainty, and ordering rules for Realtime RPCs."
---

The published schema defines methods; this page classifies replay, reconciliation, and ordering.

## Rules

- Repeat-safe means the same logical request may be sent again without creating a second logical mutation. It does not remove rate limits, provider cost, secret exposure, or fresh timestamps.
- `accepted` is diagnostic. Only an authenticated result, update, or authoritative query confirms an outcome.
- After dispatch, an unclassified mutation becomes `commitUnknown` on timeout, cancellation, disconnect, or missing result unless the owner proves execution never began. It is not automatically replayed.
- A stable-identity method is retryable only when the documented identity is present and reused and the method's replay policy permits it. Identity alone is not a general retry policy.
- Set- and delete-shaped methods are not assumed idempotent because they may emit revisions, system messages, notifications, or an error when repeated.
- `UNSPECIFIED` is rejected before execution.

Only an outer transport `rpc_error(503)` / `rpc_error(504)` carries the protocol's pre-execution rejection / commit-unknown meaning. A protobuf `RpcError` inside an authenticated application result is an ordinary method error, even when its numeric code is 503 or 504. Interpret the envelope, not only the number.

## Repeat-Safe Queries

Read-only methods may replay after reconnect with identical input. Credential-revealing, presence-refreshing, or provider-billed calls still require deliberate use.

## Stable Identity or Reconciliation

Examples include:

| Method | Required identity or reconciliation |
| --- | --- |
| `SEND_MESSAGE` | Reuse a non-zero `random_id`. |
| `CREATE_SUBTHREAD` | Reconcile the parent chat and parent message. |
| `CREATE_UPLOAD` | Reuse `(account session, client_upload_id)`. |
| `SAVE_UPLOAD_PART` | Reuse `(upload_id, part_index)` with matching bytes and hash. |
| `FINISH_UPLOAD` | Reuse the stable `upload_id` and reconcile the canonical result. |

## No Automatic Replay

Cancellation and a server deadline can end the caller's wait while the operation continues. A proven pre-execution rejection is different from an unknown commit outcome. Do not show an uncertain mutation as failed and immediately submit a fresh copy.

State-shaped operations require query or update reconciliation before retry: message edits/deletes, participant changes, dialog state, notification settings, profile changes, session updates, connector settings, upload cancellation, and DialogFolder update/delete.

Allocation and execution-sensitive operations require a stable operation identity before automatic retry: chat, bot, space, group, Grid-room, external-task, CLI-session, connector-OAuth, and DialogFolder creation.

## Ordering

Connection-local lanes serialize selected non-commutative operations for one chat, user, space, or account setting. Unrelated keys remain concurrent. This does not replace cross-connection database transactions or make a method replay-safe.

[Published method replay reference](https://github.com/inline-chat/inline/blob/main/packages/protocol/docs/realtime-v3-rpc-semantics.md)
