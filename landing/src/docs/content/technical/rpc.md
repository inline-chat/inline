---
title: "RPC Semantics"
description: "Realtime retry and reconciliation rules."
---

## Rules

- Read-only methods may replay with identical input.
- `accepted` is not a confirmed application outcome.
- After dispatch, an unclassified mutation becomes `commitUnknown` on timeout, cancellation, disconnect, or missing result.
- Retry a stable-identity method only with the same identity and a documented repeat-safe policy.
- Reconcile state-shaped mutations before retrying.
- Reject `UNSPECIFIED` before execution.
- Cancellation ends the wait, not execution.

Only outer transport `rpc_error(503)` and `rpc_error(504)` carry pre-execution or commit-unknown meaning. A protobuf `RpcError` inside an authenticated result is a method error.

## Stable Identities

- `SEND_MESSAGE`: reuse the non-zero `random_id`.
- `CREATE_SUBTHREAD`: reconcile parent chat and message.
- `CREATE_UPLOAD`: reuse `(account session, client_upload_id)`.
- `SAVE_UPLOAD_PART`: reuse `(upload_id, part_index)` with identical bytes and hash.
- `FINISH_UPLOAD`: reuse `upload_id` and reconcile the canonical result.

## No Automatic Replay

Reconcile before retry:

- Message edits and deletes.
- Participant, dialog, notification, profile, session, and connector changes.
- Upload cancellation.
- DialogFolder update and delete.

Require a stable operation identity before automatic retry:

- Chat, bot, space, group, Grid-room, external-task, CLI-session, connector-OAuth, and DialogFolder creation.

Connection-local lanes serialize selected non-commutative operations. They do not create cross-connection transactions or make methods repeat-safe.

[Complete replay matrix](https://github.com/inline-chat/inline/blob/main/packages/protocol/docs/realtime-v3-rpc-semantics.md)
