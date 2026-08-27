---
title: "RPC Semantics"
description: "Replay, reconciliation, commit uncertainty, and ordering rules for Realtime RPCs."
---

The published schema defines methods; this page classifies replay, reconciliation, and ordering.

## Rules

- Repeat-safe means the same logical request may be sent again without creating a second logical mutation. It does not remove rate limits, provider cost, secret exposure, or fresh timestamps.
- `accepted` is diagnostic. Only an authenticated result, update, or authoritative query confirms an outcome.
- After dispatch, an unclassified mutation becomes `commitUnknown` on timeout, cancellation, disconnect, or missing result. It is not automatically replayed.
- A stable-identity method is retryable only when the documented identity is present and reused.
- Set- and delete-shaped methods are not assumed idempotent because they may emit revisions, system messages, notifications, or an error when repeated.
- `UNSPECIFIED` is rejected before execution.

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

State-shaped operations require query or update reconciliation before retry: message edits/deletes, participant changes, dialog state, notification settings, profile changes, session updates, connector settings, upload cancellation, and DialogFolder update/delete.

Allocation and execution-sensitive operations require a stable operation identity before automatic retry: chat, bot, space, group, Grid-room, external-task, CLI-session, connector-OAuth, and DialogFolder creation.

## Ordering

Connection-local lanes serialize selected non-commutative operations for one chat, user, space, or account setting. Unrelated keys remain concurrent. This does not replace cross-connection database transactions or make a method replay-safe.
