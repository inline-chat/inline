---
title: "Sync"
description: "Realtime update, cursor, and history-gap rules."
---

Inline sync preserves cached state while repairing gaps.

## Buckets

- User: account, settings, profile, dialog state, space membership, and top-level chat access.
- Space: membership and space settings.
- Chat: messages, attachments, pins, metadata, visibility, participants, groups, moves, deletion, and scoped history clearing.
- Ephemeral: reactions, compose, presence, notifications, `GridEvent`, and `BotEvent`.

Each durable update maps to one inferred bucket.

## Cursor

```text
seq <= cursor      ignore
seq = cursor + 1   apply and commit
seq > cursor + 1   fence bucket and fetch
```

Only the affected bucket pauses. Do not advance past an unsupported or malformed durable update without authenticated sequence coverage.

## Catch-Up

- Page size: up to 100 logical updates.
- Replay ceiling: 10,000 updates.
- Larger gaps return `TOO_LONG` and require a snapshot.
- Validate snapshot identity and sequence.
- Commit projection and cursor together.
- Preserve the old cursor if repair fails.
- Preserve cached messages and user-owned dialog preferences.

## Discovery

Install the update collector before `GET_UPDATES_STATE`. Apply its preceding update batches before closing target collection. Fetch hinted buckets plus the user bucket; do not enumerate every stored cursor.

## History

Update continuity does not prove message-history continuity. Track message-ID gaps separately. Close a gap only after a successful history response.

- [TypeScript sync owner](https://github.com/inline-chat/inline/blob/main/sdk/src/sdk/inline-sdk-client.ts)
- [Rust sync engine](https://github.com/inline-chat/inline/blob/main/crates/client/src/sync.rs)
- [V3 update contract](https://github.com/inline-chat/inline/blob/main/packages/protocol/docs/realtime-v3.md)
