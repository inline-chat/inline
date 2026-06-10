# Sync First-Pass Investigation

Date: 2026-06-07

Scope: iOS/macOS RealtimeV2 update delivery, catch-up, local DB saving/refetching, server update rows, recent commits, and the observed production log pattern:

```text
Sync Skipping editMessage update due to missing message { chatId: 346, msgId: "3064", seq: 2302...2320 }
```

No code changes were made in this pass.

## Executive Summary

The updating state was not disabled globally. Message updates are still enabled for active chat buckets, and the client still exposes bucket fetch progress through `isUpdating`, but the current fast-forward paths can make that state invisible or too brief to observe.

The larger problem is catch-up correctness. A cold or inactive chat bucket can be marked caught up without fetching/applying its missing messages, and a malformed update sequence with missing message references can stall a bucket forever. This matches the field report: chats did not catch up globally, opening chats one by one repaired them, and sidebar last-message state was wrong until per-chat refetches ran.

The production log is likely related. Server catch-up was trying to inflate contiguous `editMessage` rows for message `3064`, but the message was missing from the server-side message table for those rows. Current server logic drops missing rows from the response, and current client logic refuses to advance past non-contiguous sequences. That is safer than lying, but without a repair/skip policy it becomes a permanent bucket stall.

## Current Architecture

Server update writers append rows to the `updates` table with bucket/entity/seq metadata and an encrypted payload. For user, space, and chat buckets to be discoverable, entity `updateSeq` and `lastUpdateDate` also need to move forward.

`getUpdatesState` is only a signal. It compares global `lastUpdateDate` against the client cursor and returns whether any user, chat, or space buckets have newer updates. It does not tell the client which chat buckets changed.

`getUpdates` fetches update rows for a specific bucket and inflates them into protobuf updates. It now returns only the contiguous inflated prefix. If row `2302` is missing/uninflatable, later rows are also withheld even if they exist.

The Apple sync actor tracks user/space/chat buckets independently. Realtime updates are buffered by sequence, catch-up fetches gaps, and `isUpdating` reflects in-flight bucket work. Message updates are intentionally enabled only for active chats.

Sidebar state depends on local `Dialog`, `Chat.lastMsgId`, and a joined `Message`. If the last message id points to a message missing from the local DB, chat saving can clear/avoid the invalid last message, and the sidebar shows stale or empty state until another path repairs it.

## Root Causes Found

### 1. Cold Chat Buckets Can Fast-Forward Past Messages

Message updates are enabled for active chat buckets, but `tooLong` handling has a fast-forward mode for chat buckets that are not message-enabled.

Key refs:

- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:24`
- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:1097`
- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:1207`
- `apple/InlineKit/Tests/InlineKitTests/RealtimeV2/SyncTests.swift:423`

This is now an explicit tested behavior. It explains why a background/cold chat can be considered caught up while never receiving the messages generated while it was inactive.

### 2. Missing Message References Stall Buckets

Server inflation skips `newMessage` and `editMessage` rows when the referenced message cannot be loaded.

Key refs:

- `server/src/modules/updates/sync.ts:268`
- `server/src/functions/updates.getUpdates.ts:150`
- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:1165`

Because `getUpdates` only returns the contiguous inflated prefix, a missing first row creates a non-progress response. The Apple client then stops advancing that bucket. This avoids corrupt advancement, but it has no repair path, so the bucket can remain stuck indefinitely.

### 3. Bad Rows Can Be Produced By Non-Atomic Writers

At least one message write path creates an update row before the message update is committed, and it also uses `db.update` inside a transaction flow rather than the transaction handle.

Key ref:

- `server/src/db/models/messages.ts:703`

There is also a subthread parent edit path that can persist a parent `editMessage` update before proving the parent message exists.

Key ref:

- `server/src/modules/subthreads.ts:376`

These paths can produce exactly the kind of row seen in production logs: an update log entry whose payload references a missing message.

### 4. Global Cursor Can Advance Independently Of Bucket Success

The client updates `lastSyncDate` after `getUpdatesState`, while actual bucket catch-up may later fail, stall, or fast-forward.

Key refs:

- `server/src/functions/updates.getUpdatesState.ts:93`
- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:383`

That means the global cursor can hide the need for future scans even when specific buckets were not actually brought to a good local state.

### 5. Chat Catch-Up Sidecars Omit Dialogs

Server catch-up includes sidecar `chats` and `users`, but not dialogs.

Key ref:

- `server/src/modules/updates/sync.ts:593`

That is risky because sidebar correctness depends on dialog rows. Opening a chat runs separate transactions that save chat/dialog/history state, which explains why opening chats one by one repaired the UI.

### 6. Apple Update Application Swallows DB Errors

Many update apply methods use `try?` and return silently if the local DB write fails.

Key refs:

- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift:825`
- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift:1243`

This makes local update loss hard to detect. A sequence can be advanced even though the corresponding local persistence failed.

### 7. Opening A Chat Repairs State Through Separate Fetch Paths

Opening a chat goes through direct transactions that fetch/save chat state and history, independent of bucket catch-up.

Key refs:

- `apple/InlineKit/Sources/InlineKit/Transactions2/GetChatTransaction.swift:48`
- `apple/InlineKit/Sources/InlineKit/Transactions2/GetChatHistoryTransaction.swift:60`
- `apple/InlineKit/Sources/InlineKit/ViewModels/FullChat.swift:390`

This explains the user-visible behavior: global catch-up did not repair everything, but per-chat open did.

### 8. Wrong Last Message Is A Data-Consistency Symptom

`Chat.saveWithValidLastMsg` validates the local last message id against local message existence. If the message is missing locally, the last message pointer can be cleared or remain stale, and sidebar queries that join through `lastMsgId` show incorrect state.

Key ref:

- `apple/InlineKit/Sources/InlineKit/Models/Chat.swift:270`

The root issue is not just display code. It is that local chat/dialog/message denormalized state is not updated atomically across all catch-up paths.

## Recent Regressions / Risky Changes

The last week includes changes that are individually understandable but dangerous in combination:

- `3144efa9 sync: harden catch-up updates`
  - Made server catch-up contiguous and client non-progress handling stricter.
  - Good safety property, but exposes missing-message rows as permanent stalls without repair.

- `31020b07 ios: gate message updates to active chat`
  - Reduced background message work.
  - Introduced the risk that inactive chat buckets are marked caught up without message bodies.

- `43fa16ce apple: avoid cached chat refetch on open`
  - Reduced redundant chat fetches.
  - In a world where global catch-up is unreliable, this removes an accidental repair path.

- `fead7c69` / `c7100b5a`
  - Clear history on refresh/logout flows.
  - Raises the cost of any catch-up weakness because local message existence becomes less reliable after reset.

- `cbdddd5a` / `678a92a9`
  - More user/chat update reliance through user bucket flows.
  - Increases dependency on robust bucket discovery and catch-up semantics.

## Sentry / Production Observability

Fresh Sentry CLI access from this environment did not return useful issue data:

- `sentry project list --json` returned an empty project list.
- `sentry org list --json` returned `403 Forbidden`.

The provided server logs are still enough to identify a concrete failure mode: repeated `editMessage` rows in chat bucket `346` reference missing message `3064`, causing skipped inflation over a contiguous sequence range.

## First-Pass Fix Plan

1. Stop cold fast-forward for message-enabled chat buckets.
   - If a chat has message updates in its bucket, `TOO_LONG` must fetch a snapshot/history window or explicitly enqueue repair, not silently set local seq to server seq.

2. Add a server repair/skip policy for invalid update rows.
   - Either reconstruct missing message payloads from durable source of truth or emit an explicit tombstone/skip update that lets clients advance with an auditable reason.
   - Do not rely on dropping rows from the response.

3. Make update writers atomic.
   - Message rows, chat/dialog denormalized state, and update rows should be committed through one transaction path.
   - Update rows should be written only after the referenced data is durable.

4. Include enough sidecar data for sidebar correctness.
   - Chat catch-up should deliver or trigger fetch of dialog/chat/message snapshot state needed for list rows.

5. Make Apple apply errors honest.
   - Replace silent `try?` update application with logged/retriable failure paths.
   - Do not advance bucket seq after a failed local DB apply.

6. Separate global discovery cursor from bucket completion.
   - `lastSyncDate` should not be the only durable memory of work discovered by `getUpdatesState`.
   - Persist pending bucket work or receive changed bucket ids directly from the server.

7. Add regression tests around the field failure.
   - Missing edit-message row does not permanently stall without repair.
   - Cold inactive chat receives messages after catch-up.
   - Sidebar last message remains correct after history reset plus catch-up.
   - Local DB apply failure does not advance seq.

