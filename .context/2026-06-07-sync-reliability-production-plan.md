# Sync Reliability Production Plan

Date: 2026-06-07

Scope: investigation, Sentry JSONL evidence extraction, Telegram comparison, and concrete low-risk remediation applied in this pass.

Source note: Sentry context below is extracted only from the saved Codex rollout JSONL at `/Users/mo/.codex/sessions/2026/06/07/rollout-2026-06-07T11-36-56-019ea11e-e2a2-7e02-bd62-e01fc1e4f1f1.jsonl`. No live Sentry CLI queries were used for this follow-up.

## Executive Summary

The current failure class is not "message updates are disabled." Message updates are now unconditional for everyone; the old Apple sync config flag was removed in this pass.

The failure class is that the system can still reach a state where it believes catch-up work has finished, stalled harmlessly, or been deferred, while the local DB and UI are not actually converged. This matches the observed behavior: macOS/iOS opened after a background period, background catch-up did not repair message panes, and direct chat opens repaired state one chat at a time through stronger `getChat` / `getChatHistory` bundles.

The production evidence recovered from the JSONL lines up with the code review:

- Catch-up apply failures are real in production and can keep chat buckets at `seq=0`.
- Non-progress `getUpdates` responses are real in production and abort bucket fetch loops.
- Local GRDB foreign-key failures are real in production while inserting messages.
- Missing local chat rows for thread peers are high-volume production events.
- Server missing-message inflation warnings exist, but the deleted-message case should be treated as secondary evidence of missing skip/tombstone semantics, not the root cause.

The Telegram lesson to copy is not the exact MTProto `pts` schema. The important property is that gaps are first-class state. Telegram buffers skipped updates, requests differences, persists holes and invalidated history state, and validates history views against that state. Inline still has paths where a gap becomes a hidden fast-forward, a retry with no durable debt, or a UI reload that can be dropped.

## Implemented In This Pass

These changes were chosen because they are backed by the JSONL evidence, match the Telegram-style invariant that cursors only move after durable application or explicit skip metadata, and have focused tests. Higher-risk protocol and UI scheduling work is left in the plan below.

1. Message update sync is unconditional.
   Removed the old `enableMessageUpdates` config/API surface from Apple sync code. Chat bucket catch-up now always processes message updates and `chatSkipPts`, so production behavior no longer depends on a local feature flag.

2. Apple bucket cursors no longer advance over failed cursor persistence.
   `SyncStorage` writes now return success/failure. `GRDBSyncStorage` reports failed writes, and the sync actor updates in-memory bucket/global state only after storage succeeds. This directly addresses false convergence when local cursor state cannot be persisted.

3. Cold chat `TOO_LONG` no longer fast-forwards message history.
   Cold chat buckets now keep slicing catch-up work instead of jumping to the server upper bound. Space/user buckets can still use the old fast-forward behavior where message history convergence is not at stake.

4. Date-only `getUpdatesState` no longer proves convergence on Apple.
   The client now treats `getUpdatesState` as discovery only and does not advance `lastSyncDate` from that response alone. Global cursor movement is tied to actually applied direct/bucket updates.

5. Old or empty Apple sync state uses bounded lookback instead of "now."
   Missing sync state and very old sync state seed a five-day lookback, not a current timestamp. This avoids converting unknown local state into "caught up."

6. Server `getUpdatesState(date=0)` uses bounded lookback instead of returning now.
   The server scans recent chat/space changes for a zero date using the same five-day window. This preserves first-run/repair discovery without an unbounded historical scan.

7. Server missing edit targets become explicit `chatSkipPts`.
   Missing `editMessage` targets are treated as obsolete/skippable and emit `chatSkipPts`, allowing contiguous progress. Missing `newMessage` targets remain strict and do not advance, because they represent potentially missing durable message state.

8. Chat catch-up sidecars include the current user's dialog.
   Server chat sidecar bundles now include dialog state for affected chats, closing part of the gap between background catch-up and the stronger `getChat`/`getChats` repair path.

9. Live/direct message updates materialize missing local references.
   Realtime/direct `newMessage` and `editMessage` application now materializes missing chat/user rows the same way catch-up already did. This targets the production GRDB foreign-key failure class without weakening lower-level strict apply tests.

Verified with:

- `cd apple/InlineKit && swift test --filter SyncTests`
- `cd apple/InlineKit && swift test --filter UnreadReplayGuardTests`
- `cd apple/InlineKit && swift test --filter RealtimeSendTests`
- `cd server && bun test src/__tests__/functions/updates.getUpdates.test.ts`
- `cd server && bun test src/__tests__/functions/updates.getUpdatesState.test.ts`
- `cd server && bun run typecheck`
- `rg -n "enableMessageUpdates|EnableSyncMessageUpdates|enableSyncMessageUpdates" apple/InlineKit apple/InlineIOS apple/InlineMac -g '!**/.env*'` returned no matches.

## Recovered JSONL Evidence

These values are snapshots from the saved rollout JSONL, so counts and `lastSeen` may now be stale.

| Short ID | Signal | Count / Users | Last Seen In JSONL | Why It Matters |
| --- | --- | ---: | --- | --- |
| `INLINE-IOS-MACOS-V` | `GRDB.DatabaseError` SQLite FK failure while `INSERT OR IGNORE` into `message` | 1,380,983 / 45 | 2026-06-07 11:55:31 UTC | Local persistence can fail before messages become durable. Bucket advancement must not treat this as applied. |
| `INLINE-IOS-MACOS-1W2` | Failed to apply 36 catch-up updates for chat bucket, keeping `seq=0` | 38,085 / 27 | 2026-06-07 11:41:09 UTC | Direct evidence that catch-up apply is failing in production, not only a theoretical code path. |
| `INLINE-IOS-MACOS-25E` | Failed to apply 2 catch-up updates for chat bucket, keeping `seq=0` | 63,564 / 2 | 2026-06-07 01:12:38 UTC | Smaller-batch version of the same failure. |
| `INLINE-IOS-MACOS-2DG` | Non-progress `getUpdates` for chat bucket, `total=0`, `result=empty`, aborting loop | 2,909 / 1 | 2026-06-07 08:11:54 UTC | Confirms a server/client state where the client cannot move a bucket and only schedules retries. |
| `INLINE-IOS-MACOS-29B` | Failed to apply 1 realtime update, kept bucket seq and scheduled catch-up | 11,742 / 1 | 2026-06-07 08:11:39 UTC | Realtime can fail into catch-up, so catch-up must be a repair path, not another best-effort path. |
| `INLINE-IOS-MACOS-29R` | Failed direct updates, skipped direct cursor advancement | 7 / 1 | 2026-06-07 05:32:24 UTC | Direct path has some cursor protection, but failures still need durable repair and observability. |
| `INLINE-IOS-MACOS-R` | Failed to find chat for peer `thread(id: 2796)` | 1,653,815 / 74 | 2026-06-07 11:55:33 UTC | Local chat/thread references are often missing at read/apply time. Sidecars and snapshots are incomplete. |
| `INLINE-IOS-MACOS-2BA` | Failed to find chat for peer `thread(id: 2811)` | 13,316 / 1 | 2026-06-07 08:11:38 UTC | Same missing-chat class, newly concentrated on one peer. |

Server logs in the JSONL also show repeated `Skipping editMessage update due to missing message` and some `Skipping newMessage update due to missing message` entries on trace `8ba41c70f6bb4989a2897cdddf262680`, plus `error handling message` logs around 2026-06-07 11:55 UTC. Because the user confirmed at least the provided edit target was already deleted, this should not be treated as the incident root cause. It is still useful evidence that the protocol needs explicit obsolete-update semantics instead of confusing warning-only inflation drops.

## Current Implementation Findings

1. Updating UI is not a correctness signal.
   `publishSyncActivityIfNeeded` only reports active sync while `activeBucketFetches > 0` (`Sync.swift:628`). `getUpdatesState` discovery is outside that counter, and the UI display has delay policy. A real catch-up can be missed visually if it finishes, stalls, or fast-forwards inside that window.

2. Global discovery used to outrun bucket convergence.
   Before this pass, Apple advanced `lastSyncDate` from `getUpdatesState` immediately and server `getUpdatesState` treated `date === 0n` as "return now." That was fast, but made global discovery independent of whether each discovered bucket was durably repaired. Apple now treats `getUpdatesState` as discovery only, and the server uses a bounded recent scan for `date=0`.

3. Cold chat bucket `TOO_LONG` used to fast-forward history.
   On a cold bucket, Apple asks for a capped catch-up. Before this pass, if the server returned `TOO_LONG`, the client could set `finalSeq` to the upper bound and discard pending updates. Cold chat buckets now slice instead of fast-forwarding.

4. Server non-progress is now protected from spinning, but not repaired.
   `server/src/functions/updates.getUpdates.ts` uses contiguous delivery so it does not advance over uninflatable rows. Apple then logs non-progress and aborts the fetch loop (`Sync.swift:1169`). This avoids CPU loops, but leaves no durable hole/repair state.

5. Catch-up filtering and server inflation used to disagree on skips.
   Server could map unsupported rows to `chatSkipPts`, while Apple catch-up did not process it. Apple now treats `chatSkipPts` as cursor-bearing metadata, and the server uses it for missing edit targets while keeping missing new messages strict.

6. Chat sidecars used to omit dialogs.
   Apple sidecar application can save dialogs if present, but the server did not send them for chat catch-up. Server chat sidecars now include current-user dialogs for affected chats.

7. Some Apple apply and storage paths swallowed critical failures.
   Cursor storage now returns failure to the sync actor and prevents cursor advancement. Some non-cursor update apply methods still catch and log inside throwing functions; those remain a follow-up target where the risk/reward is clear.

8. Direct open is stronger than background catch-up.
   `GetChatHistoryTransaction` saves returned messages and emits a reload (`GetChatHistoryTransaction.swift:81`). `FullChat.refetchHistoryOnly` calls `getChatHistory` on foreground/open (`FullChat.swift:419`). That explains the observed one-chat-at-a-time repair.

9. iOS active-chat publishing made recovery non-durable.
   `MessagesPublisher` is a `PassthroughSubject` (`FullChatProgressive.swift:1065`). Inactive chat publishes are suppressed, and `activateChat` sends a reload event (`FullChatProgressive.swift:1071`). If activation happens before the message view model subscribes, the recovery reload can be dropped.

10. Server bucket sequence allocation is too fragile.
    `UpdatesModel.insertUpdate` computes `seq` from the caller-provided entity (`server/src/db/models/updates.ts:62`). That is only safe if every writer locks a fresh row and emits exactly one update. Chat/space buckets need the safer atomic allocator pattern already used for user bucket updates.

## Telegram-Informed Invariants

Local Telegram references checked:

- `tdesktop/Telegram/SourceFiles/data/data_pts_waiter.cpp`: buffers skipped updates and only applies contiguous points.
- `tdesktop/Telegram/SourceFiles/api/api_updates.cpp`: difference handling and `differenceTooLong` path.
- `Telegram-iOS/submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift`: stores channel `invalidatedPts` and handles too-long/difference cases.
- `Telegram-iOS/submodules/TelegramCore/Sources/State/Holes.swift`: fetches chat-list and message-history holes.
- `Telegram-iOS/submodules/TelegramCore/Sources/State/ManagedMessageHistoryHoles.swift` and `ManagedChatListHoles.swift`: bounded workers drain persisted holes.
- `Telegram-iOS/submodules/TelegramCore/Sources/State/HistoryViewStateValidation.swift`: visible history is validated against invalidated state.

Inline should adopt these invariants:

1. A cursor moves only after contiguous durable application or an explicit server-authored skip/tombstone.
2. An unreplayable span becomes durable repair debt, not a hidden success.
3. Chat-list holes and message-history holes are separate because they repair different views.
4. `TOO_LONG` invalidates the affected history view before any fast-forward is allowed.
5. UI subscriptions are consumers of durable DB/repair state, not the owner of recovery.

## Ordered Implementation Plan

### Phase 0 - Stop false convergence

Goal: prevent clients from marking chat buckets caught up when message/history state is not trustworthy.

1. Remove cold chat-bucket fast-forward for message sync. Done for chat buckets in this pass.
   In `Sync.swift`, when `payload.resultType == .tooLong`, `isColdStart == true`, and `key == .chat`, do not advance `seq` to `hardEndSeq` / `payload.seq` without replay or repair. The current implementation slices instead of fast-forwarding; a first-class repair marker remains future protocol work.

2. Use an existing snapshot repair as the immediate fallback. Deferred.
   Until the protocol grows a first-class snapshot result, the client should repair the peer through the same stronger path as direct open: fetch current chat metadata plus a bounded latest history window, then mark history invalidated/dirty if the old span was not replayed. This avoids downloading huge history while making the visible latest state correct.

3. Make `chatSkipPts` a cursor-bearing apply item. Done in this pass.
   Apple catch-up must process `chatSkipPts` as server-authored cursor advancement metadata. It should not trigger UI changes, but it must be counted as applied for seq continuity.

4. Split legitimate obsolete edits from corrupt missing messages. Partly done in this pass.
   Server inflation now emits `chatSkipPts` for missing `editMessage` targets and keeps missing `newMessage` rows strict. A richer proof/reason field for obsolete edits remains protocol work.

5. Make critical Apple apply failures throw. Partly done in this pass.
   Sync cursor storage failures now prevent cursor advancement, and live/direct message updates materialize missing references instead of producing FK failures. Broader conversion of catch-and-log update handlers remains follow-up work.

6. Add durable active-chat dirty state.
   Replace the "activation sends a reload on a `PassthroughSubject`" recovery with a durable per-peer dirty marker or view-model load check. A late subscriber must see "this peer changed while inactive" from DB/state and reload once.

7. Include dialogs in chat catch-up repair bundles. Done in this pass.
   Add current-user dialog sidecars for chat catch-up whenever an update can affect sidebar/read/archive/follow/open state. This closes the gap between background catch-up and `getChat`/`getChats`.

### Phase 1 - Server update log hardening

Goal: guarantee that update rows and bucket seqs are generated from committed source data.

1. Add atomic seq allocators for chat and space buckets.
   Do not compute chat/space seq from a stale caller row. Lock or atomically update the bucket owner row, derive next seq inside the transaction, insert the update, and set `updateSeq` / `lastUpdateDate` from the inserted row.

2. Audit all chat/space update writers.
   For each writer using `UpdatesModel.insertUpdate`, verify it locks the fresh owner row, writes exactly the intended number of updates, and validates all referenced rows before insert. High-priority paths: `messages.editMessage`, `persistMessageRepliesUpdate`, subthread follow/open updates, chat move, delete/clear history, participant changes, attachment updates, reactions/url previews if they become durable.

3. Fix transaction boundary mistakes.
   Any writer inside a transaction must use the transaction handle for dependent reads/writes. `messages.editMessage` needs particular review because the earlier audit found a global `db.update(messages)` inside a transaction-shaped flow.

4. Add an update-log integrity audit job.
   The job should scan encrypted update payloads using existing decrypt helpers, verify referenced messages/chats/dialogs exist or are provably obsolete, and report counts by update type/chat. It must not log message text, decrypted payloads, or user-sensitive content.

### Phase 2 - Protocol repair semantics

Goal: make holes and snapshots explicit across server and clients.

1. Add result classifications beyond `TOO_LONG`.
   Add protocol states such as `REPAIR_REQUIRED`, `SNAPSHOT`, and `SKIP/TOMBSTONE` rather than overloading empty/non-final responses.

2. Add server-authored skip/tombstone updates.
   A skip must include bucket, seq, reason, and enough metadata for observability. It should be produced only by server logic that has proven the update is obsolete or intentionally transient.

3. Add chat snapshot sidecars.
   For repair-required chat buckets, return a bounded current-state bundle: chat, current-user dialog, last message and sender refs, parent/space refs, latest visible message window if needed, and read/unread summary.

4. Add durable client repair tables.
   Apple should persist bucket repair debt separately from normal bucket cursors: peer, start seq, target seq, reason, last error, retry time, and invalidated-history marker. Global discovery should not advance past undiscovered bucket debt unless that debt is stored durably.

5. Add chat-list and history holes.
   Sidebar validity and message-history validity need separate markers. A repaired sidebar does not prove the message pane is complete.

### Phase 3 - Scheduling, UX, and observability

Goal: make repair fast without reviving the performance problems active-chat gating was trying to solve.

1. Prioritize visible state.
   On reconnect/foreground, repair user bucket first, then sidebar/top dialogs, then active chat, then recently visible chats, then background buckets.

2. Bound concurrency and payload sizes.
   Keep the current global fetch limiter, but add separate limits for snapshot repair and history-hole repair. Measure send/open-chat latency so repair work does not regress latency-critical paths.

3. Make updating state honest.
   UI should show updating when discovery, bucket fetch, or durable repair debt is active. It should distinguish transient network retry from "history repair pending" in logs/diagnostics, even if the user-facing UI stays simple.

4. Add production counters.
   Track `bucket_repair_required`, `bucket_repair_completed`, `bucket_repair_failed`, `skip_tombstone_applied`, `cold_too_long_invalidated`, `apply_db_failure`, `cursor_storage_failure`, `direct_open_repaired_stale_peer`, and `late_subscriber_reload_from_dirty_state`.

## Test Plan

Server tests:

1. `getUpdates` missing `newMessage` row returns repair-required and does not advance seq.
2. Deleted-target `editMessage` emits a server-authored skip/tombstone and allows contiguous advancement.
3. `chatSkipPts` / tombstones are contiguous and sidecars are not required for them.
4. Chat catch-up sidecars include current-user dialog and last-message dependencies for sidebar-affecting updates.
5. Concurrent chat and space update writers allocate strictly monotonic seqs.
6. `messages.editMessage` cannot commit an update row when the message update affected zero rows.
7. `persistMessageRepliesUpdate` verifies parent message existence or emits explicit repair semantics.

Apple tests:

1. Cold chat `TOO_LONG` does not mark the bucket complete without replay, repair debt, or snapshot repair.
2. A `chatSkipPts` / tombstone update advances the bucket cursor without UI publish work.
3. A DB failure while saving message/chat/dialog state makes `applyUpdates` fail and prevents bucket cursor advancement.
4. A sync cursor storage failure is visible to the sync actor and prevents false success.
5. Chat sidecars with dialogs repair sidebar rows without requiring direct `getChat`.
6. Inactive-chat updates set durable dirty state; a late subscriber reloads from DB even if it missed the `PassthroughSubject` event.
7. A GRDB FK fixture reproduces the `message` insert failure class and confirms repair/cursor behavior.
8. Offline-to-foreground integration: seed stale DB, deliver bucket hints, run catch-up, verify sidebar and active message pane converge without manual direct open.

## Rollout Plan

1. Ship server skip/tombstone and repair-required semantics behind a protocol capability gate.
2. Ship Apple handling for old and new server semantics before enabling new server results broadly.
3. Enable Phase 0 no-fast-forward behavior for internal/dev builds first, then beta, then stable.
4. Run an update-log audit before enabling automatic skips for obsolete updates.
5. Canary metrics must show catch-up apply failures, non-progress responses, and direct-open repairs trending down before broad rollout.
6. Keep a kill switch for snapshot repair concurrency and payload limits.

## Production Readiness

Improved, but not yet at the desired reliability bar. This pass removes several false-convergence paths, but the system still needs first-class repair debt, broader apply-failure propagation, and durable UI invalidation before direct chat open is no longer a necessary repair escape hatch.

Security risk: the proposed audit and repair logs must never emit decrypted message text, payload blobs, tokens, or user-sensitive fields. Only ids, update types, seq ranges, and aggregate counts should be logged.

Performance risk: snapshots and history-hole repairs can regress reconnect, foreground, send, and open-chat latency if unbounded. The rollout must keep strict concurrency/payload caps and measure latency-critical paths.

Production-ready target: no chat bucket fast-forward without repair state, no cursor advancement after swallowed DB errors, no non-progress loop without durable debt, and no need for direct chat open to repair normal background catch-up.
