# Unread/Read/Badge Quick Wins Plan (Low Risk)

Date: 2026-02-28
Owner areas: Server (`server/`), Apple (`apple/InlineKit`, `apple/InlineMac`, `apple/InlineIOS`)
Scope: Improve correctness and consistency of unread/read/badge behavior with minimal product risk and no protocol redesign.

## Goals
- Reduce unread/read state drift across sessions/devices.
- Make badge behavior predictable and consistent across Apple clients.
- Improve reliability of read cursor updates under concurrency.
- Add observability so we can validate improvements with production data.

## Non-goals
- No major unread model redesign.
- No web changes in this plan.
- No changes to chat ranking or notification policy.

## Current Pipeline Snapshot
- Server source-of-truth fields are `dialogs.readInboxMaxId`, `dialogs.readOutboxMaxId`, `dialogs.unreadMark` in [dialogs.ts](/Users/mo/dev/inline/server/src/db/schema/dialogs.ts:35).
- Server read mutation path is [messages.readMessages.ts](/Users/mo/dev/inline/server/src/functions/messages.readMessages.ts:24), unread-mark path is [messages.markAsUnread.ts](/Users/mo/dev/inline/server/src/functions/messages.markAsUnread.ts:21).
- Client sync applies read/unread updates in [Updates.swift](/Users/mo/dev/inline/apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift:900).
- Apple local read API is [UnreadManager.swift](/Users/mo/dev/inline/apple/InlineKit/Sources/InlineKit/ViewModels/UnreadManager.swift:96).
- macOS dock badge service is [DockBadgeService.swift](/Users/mo/dev/inline/apple/InlineMac/Services/DockBadge/DockBadgeService.swift:11) and aggregate source is [UnreadDMCount.swift](/Users/mo/dev/inline/apple/InlineKit/Sources/InlineKit/ViewModels/UnreadDMCount.swift:10).

## Phase 1 (Highest Impact, Very Low Risk)

1. Make read cursor update atomic in DB
- Problem: `readInboxMaxId` is monotonic in process, but current read-then-update pattern can race under concurrent requests.
- Change: update using SQL `GREATEST(existing, incoming)` in the mutation query inside [messages.readMessages.ts](/Users/mo/dev/inline/server/src/functions/messages.readMessages.ts:123).
- Risk: low (tight, local server change).
- Validation: concurrent read requests never decrease `readInboxMaxId`; no regression in read receipts.

2. Add explicit no-op/idempotency guard for stale reads
- Problem: stale/duplicate `readMessages` calls still perform work and fanout.
- Change: return early when incoming `maxId <= dialog.readInboxMaxId` after normalization in [messages.readMessages.ts](/Users/mo/dev/inline/server/src/functions/messages.readMessages.ts:91).
- Risk: low.
- Validation: lower write/update volume, unchanged UI behavior.

3. Add observability around read/unread transitions
- Problem: hard to measure drift and mutation quality.
- Change: structured logs/metrics around:
- `readMessages` accepted/no-op/error in [messages.readMessages.ts](/Users/mo/dev/inline/server/src/functions/messages.readMessages.ts:24).
- `markAsUnread` accepted/no-op/error in [messages.markAsUnread.ts](/Users/mo/dev/inline/server/src/functions/messages.markAsUnread.ts:21).
- realtime fanout success/failure count in [realtime/message.ts](/Users/mo/dev/inline/server/src/realtime/message.ts:260).
- Risk: low.
- Validation: dashboards for no-op ratio, fanout failures, per-user mutation rates.

## Phase 2 (Client Consistency, Low Risk)

4. Fix partial-read local optimism gap in Apple
- Problem: `readMessages(maxId:)` path has TODO and does not apply full local optimistic state, causing visible lag until server echo.
- Change: implement local state update in [UnreadManager.swift](/Users/mo/dev/inline/apple/InlineKit/Sources/InlineKit/ViewModels/UnreadManager.swift:80) similar to `readAll` flow in [UnreadManager.swift](/Users/mo/dev/inline/apple/InlineKit/Sources/InlineKit/ViewModels/UnreadManager.swift:112).
- Risk: low-medium (client-only, no protocol changes).
- Validation: opening/scrolling chat clears counters immediately and remains stable after server updates.

5. Align badge semantics with unread mark policy
- Problem: macOS dock badge aggregates only `unreadCount`; manual `unreadMark` can be excluded depending on intended product behavior.
- Change: choose and enforce one policy:
- Include `unreadMark` in [UnreadDMCount.swift](/Users/mo/dev/inline/apple/InlineKit/Sources/InlineKit/ViewModels/UnreadDMCount.swift:10), or
- Explicitly document that dock badge ignores mark-unread and add tests.
- Risk: low (policy + small query/UI adjustment).
- Validation: deterministic badge behavior for mark-unread scenarios.

6. Add iOS badge ownership path
- Problem: iOS requests notification permission but has no clear centralized badge update/clear pipeline.
- Change: add a small iOS badge coordinator analogous to macOS dock badge flow, with foreground recompute and logout clear, anchored near [AppDelegate.swift](/Users/mo/dev/inline/apple/InlineIOS/AppDelegate.swift:100).
- Risk: low-medium (isolated iOS app-layer behavior).
- Validation: app icon badge matches unread aggregate and clears on read/logout.

## Phase 3 (Performance/Polish, Still Low Risk)

7. Remove O(n^2) unread join patterns in server list responses
- Problem: chat list functions map unread counts with repeated `.find`.
- Change: switch unread results to map/dictionary lookup in:
- [messages.getChats.ts](/Users/mo/dev/inline/server/src/functions/messages.getChats.ts:415)
- [getDialogs.ts](/Users/mo/dev/inline/server/src/methods/getDialogs.ts:384)
- [getPrivateChats.ts](/Users/mo/dev/inline/server/src/methods/getPrivateChats.ts:163)
- Risk: low.
- Validation: lower p95 on list endpoints for high-chat users.

8. Add empty-input fast path in batch unread query
- Problem: avoid unnecessary DB query when no chat IDs.
- Change: guard in [dialogs.ts model](/Users/mo/dev/inline/server/src/db/models/dialogs.ts:12).
- Risk: very low.
- Validation: zero-query behavior on empty lists.

## Rollout Order
1. Phase 1.1 + 1.2 together (server correctness).
2. Phase 1.3 immediately after (instrumentation to verify impact).
3. Phase 2.4 (partial-read local optimism) before badge semantics changes.
4. Phase 2.5 and 2.6 (badge policy + iOS badge ownership).
5. Phase 3 performance polish.

## Testing and Validation Checklist
- Server focused tests for monotonic read cursor and duplicate read no-op behavior.
- Realtime sync test: active session + reconnect session receive consistent `updateReadMaxId`/`markAsUnread`.
- Apple manual matrix:
- iOS foreground open-chat auto-read.
- macOS active/inactive window read behavior.
- mark unread then read then reconnect across devices.
- Badge matrix:
- unread incoming message.
- manual mark unread with no unread count.
- read all.
- logout/login.
- Metrics review 48h after rollout for fanout errors, no-op ratios, and read/update latency.

## Security and Production Readiness
- No high-severity security issues identified in this pipeline review.
- Top production-readiness item is atomic monotonic read cursor updates on server to avoid rare consistency regressions.
