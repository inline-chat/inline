---
title: "Sync"
description: "Durable update buckets, cursors, live delivery, and discovery."
---

Inline sync keeps a local projection current by applying ordered durable updates and fetching missing ranges. A realtime connection delivers changes promptly; the server's durable update journal lets clients recover after disconnects. Read this page for the cursor model, then use [Sync recovery](/docs/technical/sync-recovery) to implement gap handling.

## Buckets

A **bucket** is one independently sequenced stream. A **cursor** is the highest bucket sequence the client has safely applied or otherwise accounted for. A **projection** is materialized local state, such as a dialog list or chat view. Possessing a cursor alone does not prove a projection was rebuilt correctly.

| Bucket | Durable state it can carry |
| --- | --- |
| User | Account and profile changes, settings, dialog state, and top-level chat access. |
| Space | Space membership and space-scoped settings. |
| Chat | Messages, attachments, pins, metadata, visibility, participants, groups, moves, deletion, and scoped history clearing. |

Durable records have one bucket sequence. Wire events such as `chatHasNewUpdates`, `spaceHasNewUpdates`, and `userHasNewUpdates` are hints: they identify work to fetch but do not replace the corresponding journal page. Ephemeral activity such as typing, presence, `GridEvent`, and `BotEvent` does not advance a durable bucket cursor. Do not use a hint or ephemeral event as proof that a projection is complete.

## Cursor

For a bucket already at cursor 41, a durable update at 42 is the next candidate to apply; 41 or earlier is duplicate coverage; 44 exposes a missing 42–43 range. Fence that bucket and fetch the missing range. Other buckets can continue.

```text
seq <= cursor      duplicate: ignore
seq = cursor + 1   apply, then commit coverage
seq > cursor + 1   fence this bucket; fetch from cursor
```

Commit the projection and its cursor as one durable unit when the host owns materialized state. If a host handler fails or does not acknowledge delivery, keep the old cursor and retry recovery. A later live event cannot close an earlier gap by merely arriving.

`GET_UPDATES` returns a slice after `start_seq` for a user, space, or chat bucket. It caps a page at 100 logical records and may return fewer to target a response below 1,000,000 bytes; one indivisible record can exceed that byte target. A page's `seq` is the covered end, and every advanced sequence must appear either in `updates` or `skipped_sequences` with a recognized reason. `IRRELEVANT_TO_BUCKET` accounts for a sequence without a projection change. `SNAPSHOT_REPAIR_REQUIRED` means a materialized host must replace affected state before treating it as applied. Unknown reasons and unaccounted sequences require recovery, not a speculative cursor advance.

## Discovery

`GET_UPDATES_STATE` accepts an optional date checkpoint and returns a new checkpoint, an optional `updates_found` flag, and the current user-bucket sequence. With a saved date, the server scans changed accessible chats and spaces and emits bucket hints before returning the result. An absent date asks for a fresh checkpoint; initial snapshots and bucket cursors must be seeded independently.

Install the update collector before requesting discovery. Process wire-ordered hint batches that precede the RPC result, fetch their target buckets and required user-bucket work, then persist the new date checkpoint. If a target or checkpoint write fails, keep the prior date so the next discovery can find the work again. A date checkpoint identifies what was *discovered*; bucket cursors identify what was *applied*.

The server uses an inclusive date scan, so a later discovery can report a target again. Deduplicate using bucket sequence and projection identity. Discovery does not require fetching every locally stored bucket cursor on every reconnect.

## Catch-Up

The server may deliver a durable update live, replay it in a `GET_UPDATES` page, or deliver only a hint that prompts a fetch. Handle duplicates by bucket sequence. Keep cached projections while a bucket is recovering; replace only state owned by the repaired bucket when an authoritative snapshot is necessary. A missing item in an unrelated snapshot is not proof of deletion.

## History

Update continuity and message-history continuity are separate. A chat can have a current update cursor while older message pages remain unloaded or a local history interval is unknown. See [history continuity](/docs/technical/sync-recovery#history-continuity) before treating an update cursor as proof that all messages are present.

## Implementation sources

- [Wire schema](https://github.com/inline-chat/inline/blob/main/proto/core.proto) defines buckets, discovery, pages, and skip reasons.
- [Server update pages](https://github.com/inline-chat/inline/blob/main/server/src/functions/updates.getUpdates.ts) enforce pagination and replay limits.
- [TypeScript SDK sync owner](https://github.com/inline-chat/inline/blob/main/packages/sdk/src/sdk/inline-sdk-client.ts) handles live admission and catch-up.
- [Rust client sync engine](https://github.com/inline-chat/inline/blob/main/crates/client/src/sync.rs) journals updates and cursor progress.
