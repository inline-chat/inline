---
title: "Sync"
description: "Updates, cursors, catch-up, snapshots, and message-history coverage."
---

Inline sync preserves cached state while repairing update and history gaps.

## Buckets

Every durable update maps to one inferred bucket; the update does not carry the bucket.

| Bucket | Owns |
| --- | --- |
| User | Account, settings, profile, dialog open/archive/follow/read/unread state, space join/leave, and top-level chat access. |
| Space | Membership and space settings. |
| Chat | Messages, attachments, pins, metadata, visibility, participants, groups, moves, deletion, and scoped history clearing. |

Reactions, compose and presence state, new-message notifications, `GridEvent`, and `BotEvent` are ephemeral. They do not share the durable bucket replay contract.

## Cursor and Target

Each durable bucket has one committed cursor and one volatile target.

```text
stale or duplicate       seq <= cursor      ignore
contiguous               seq = cursor + 1   apply and commit
gap                      seq > cursor + 1   fence bucket and fetch
```

Only the affected bucket pauses. An unsupported update kind may be an application no-op only when the authenticated page provides complete `updates + skipped_sequences` coverage for the interval. A malformed update the client claims to support is an apply failure; do not advance the cursor past it.

## Catch-Up

Clients replay pages of at most 100 logical updates for gaps through the 10,000-update replay ceiling. Larger gaps return `TOO_LONG` and require an authoritative snapshot. The returned sequence is a target, not permission to fast-forward without installing its projection.

- User repair fetches the current checkpoint, chats, user, and settings.
- Space repair fetches the space, current membership, and small space settings rather than the full member list.
- Chat repair fetches the chat and bounded recent history while preserving cached messages and user-owned dialog preferences.

Snapshot identity and sequence are validated before projection and cursor commit together. A failed repair preserves the previous cursor.

## Reconnect Discovery

Install the update collector before discovery. `GET_UPDATES_STATE` emits targeted chat and space hints; fetch those buckets plus the user bucket rather than enumerating every stored cursor.

The server queues a discovery call's hints before its RPC result on the same stream. Hand those preceding batches to the sync owner before closing target collection. A socket opening, an RPC completing, or an event-loop delay does not prove the targeted buckets have converged.

## History Gaps

Update continuity does not prove message-history continuity. Clients track unknown message-ID intervals separately. Only a successful history response closes an interval; isolated messages do not prove surrounding history is complete.

Cached messages remain available on the first frame. A per-chat repair owner fetches gaps as the visible window reaches them rather than replacing the whole chat.

## Implementations

- [TypeScript SDK sync owner](https://github.com/inline-chat/inline/blob/main/sdk/src/sdk/inline-sdk-client.ts)
- [Rust client sync engine](https://github.com/inline-chat/inline/blob/main/crates/client/src/sync.rs)
- [Realtime V3 update contract](https://github.com/inline-chat/inline/blob/main/packages/protocol/docs/realtime-v3.md)
