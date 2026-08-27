---
title: "Sync"
description: "Updates, cursors, catch-up, snapshots, and message-history coverage."
---

Inline sync preserves cached state while repairing update and history gaps.

## Buckets

Every durable update maps to one inferred bucket; the update does not carry the bucket.

| Bucket | Owns |
| --- | --- |
| User | Account, settings, profile, dialog open/archive/follow/read state, space join/leave, and top-level chat access. |
| Space | Membership and space settings. |
| Chat | Messages, attachments, pins, metadata, visibility, participants, groups, moves, deletion, and scoped history clearing. |

Reactions, compose and presence state, and new-message notifications are ephemeral.

## Cursor and Target

Each durable bucket has one committed cursor and one volatile target.

```text
stale or duplicate       seq <= cursor      ignore
contiguous               seq = cursor + 1   apply and commit
gap                      seq > cursor + 1   fence bucket and fetch
```

Only the affected bucket pauses. Unknown future updates are accounted no-ops; known reducer failures do not advance the cursor.

## Catch-Up

Clients replay bounded pages for ordinary gaps. Beyond the replay window, `TOO_LONG` requires an authoritative snapshot. A snapshot sequence is a target, not permission to fast-forward without installing its projection.

- User repair fetches the current checkpoint, chats, user, and settings.
- Space repair fetches the space, current membership, and small space settings rather than the full member list.
- Chat repair fetches the chat and bounded recent history while preserving cached messages and user-owned dialog preferences.

Snapshot identity and sequence are validated before projection and cursor commit together. A failed repair preserves the previous cursor.

## History Gaps

Update continuity does not prove message-history continuity. Clients track unknown message-ID intervals separately. Only a successful history response closes an interval; isolated messages do not prove surrounding history is complete.

Cached messages remain available on the first frame. A per-chat repair owner fetches gaps as the visible window reaches them rather than replacing the whole chat.

## Implementations

- [TypeScript SDK sync owner](https://github.com/inline-chat/inline/blob/main/sdk/src/sdk/inline-sdk-client.ts)
- [Rust client sync engine](https://github.com/inline-chat/inline/blob/main/crates/client/src/sync.rs)
- [Realtime V3 update contract](https://github.com/inline-chat/inline/blob/main/packages/protocol/docs/realtime-v3.md)
