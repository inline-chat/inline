# Sync Reliability + Gap Repair (2026-02-07)

From notes (Feb 3-7, 2026): "fix sync", "sync gaps", "prevent quick connecting states", "intermittent connecting state too often".

Related deep dives already in repo:
- `/.agent-docs/2026-02-07-sync-engine-deep-dive.md`
- `/.agent-docs/2026-01-07-sync-review-findings.md`

## Goals

- No silent state divergence: messages and critical chat state should converge after reconnect/background/offline.
- No update storms: reconnect should not trigger repeated `getUpdatesState` rescans or unbounded bucket fetch fanout.
- Deterministic sequencing: bucketed updates apply in strict `seq` order; out-of-order delivery repairs gaps instead of skipping.
- UX: avoid showing "connecting" for brief, expected transient states.

## Non-Goals (For Tomorrow)

- Multi-account.
- Perfect "full sync" for every entity type (reactions/attachments) unless already required for correctness.
- Replacing the entire sync engine; focus on incremental fixes with clear tests.

## Current Architecture (What Exists)

Server:
- Buckets via `updates` table; per-entity `seq` increments and `lastUpdateDate` used for scanning.
- Key files: `server/src/db/schema/updates.ts`, `server/src/functions/updates.getUpdates.ts`, `server/src/functions/updates.getUpdatesState.ts`, `server/src/modules/updates/sync.ts`.

Apple (RealtimeV2):
- `RealtimeV2.Sync` treats `chatHasNewUpdates` / `spaceHasNewUpdates` as signals and triggers per-bucket fetch.
- Key file: `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift`.

## High-Confidence Problems (Root Causes Of Gaps)

1. Catch-up drops message updates by default.
- `BucketActor` filters update kinds during catch-up using `enableMessageUpdates` toggle.
- Default `enableMessageUpdates = false` means reconnect catch-up will not replay messages, producing permanent message gaps for most users.

2. TOO_LONG and "old state" recovery currently fast-forwards without repairing local state.
- When the server says "TOO_LONG" (or large gap), client advances `seq/date` and discards the missing update range.
- When last sync state is very old, client resets cursor to "now" without any cache clear/refetch.

3. Sequencing is not strict across direct updates vs fetched history.
- If a newer direct update advances `self.seq`, older missing seqs can be treated as duplicates and dropped.
- There is no per-bucket "expected next seq" enforcement, buffering, or gap detection for push updates.

4. `getUpdatesState` cursor can fail to advance.
- When there are no updated chats/spaces, returning `date=0` or a stale cursor causes repeated rescans and repeated signaling.

5. Side effects during catch-up can be expensive and incorrect.
- Applying `.newMessage` during catch-up can increment unread and trigger notifications as if they were realtime.
- Catch-up should be idempotent and suppress user-visible side effects.

## Proposed Fix Plan (Phased, Implementable)

### Phase 0 (Tomorrow morning, 30-60 min): Instrumentation

- Use existing Sync stats UIs to get a baseline: `apple/InlineMac/Views/Settings/Views/SyncEngineStatsDetailView.swift`, `apple/InlineIOS/Features/Settings/SyncEngineStatsView.swift`.
- Add targeted logs (minimal, behind DEBUG if needed).
- Server: log `TOO_LONG` and `latestSeq-startSeq` in `server/src/functions/updates.getUpdates.ts`.
- Server: log returned cursor + counts in `server/src/functions/updates.getUpdatesState.ts`.
- Client: log when catch-up drops message updates (until default is flipped).

### Phase 1 (Tomorrow): Correctness Fixes That Remove Gaps

1. Make catch-up include message updates by default.
- Flip the default for `enableMessageUpdates` to true.
- Add explicit suppression of side effects (see Phase 2) to keep this safe.

2. Fix `getUpdatesState` cursor advancement.
- If there are no updated chats/spaces after cursor, return a sensible new cursor (for example: server "now").
- Stop using `date=0` as a meaningful cursor.

3. Enforce per-bucket sequencing (gap detection + buffering).
- Route all seq-bearing bucketed updates through a per-bucket sequencer.
- Maintain `expectedSeq = lastAppliedSeq + 1`.
- If push delivers `seq > expectedSeq`, buffer it and trigger `getUpdates(startSeq=expectedSeq)` until the gap is filled.
- Drain buffered updates once contiguous.

4. Add fetch retry/backoff and global concurrency cap.
- If a bucket fetch fails, retry with exponential backoff (bounded).
- Cap concurrent bucket fetch loops to avoid a thundering herd.

5. Replace TOO_LONG fast-forward with targeted repair.
- On TOO_LONG, mark bucket as "needs repair" and perform a higher-level refresh.
- Chat bucket repair: fetch chat history around most recent known message, then continue normal sequencing.
- If chat history isn't sufficient: clear local history for that chat and refetch last N messages.
- Do not silently advance seq/date without doing a repair action.

### Phase 2 (Immediately after Phase 1): Make Message Catch-up Safe

1. Introduce an "apply source" context for updates.
- Example: `.realtimePush` vs `.syncCatchup`.
- In catch-up mode: do not fire notifications; do not increment unread counters naively; prefer coalesced "chat changed" events over per-message publishers.

2. Make message apply idempotent.
- If message already exists in DB, do not re-trigger unread/notification logic.
- Guard side-effect logic behind "inserted vs already present" checks.

### Phase 3 (Next few days): Completeness + Scalability

- Decide if reactions/attachments must be part of bucket sync or if history fetch is the source of truth.
- Consider adding a server "slice boundary" response to avoid TOO_LONG for common cases (optional).

## UX: Reduce "Connecting" Churn

Problem: UI maps too many internal states to a single "connecting" label.

Plan:
- Expose reason codes from connection manager snapshots.
- Map to distinct UI states: waiting for network; reconnecting in Xs (backoff); updating (during catch-up); connecting (handshake in progress).
- Tune `ConnectionPolicy` timeouts for constrained networks, and consider requiring 2 ping failures before full reconnect.

Files:
- `apple/InlineKit/Sources/RealtimeV2/Connection/ConnectionManager.swift`
- `apple/InlineKit/Sources/RealtimeV2/Realtime/Realtime.swift` (state mapping)

## Concrete File Touchpoints (Non-exhaustive)

Server:
- `server/src/functions/updates.getUpdatesState.ts`
- `server/src/functions/updates.getUpdates.ts`
- `server/src/modules/updates/sync.ts`

Apple:
- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift`
- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift`
- `apple/InlineKit/Sources/RealtimeV2/Realtime/Realtime.swift`

## Testing Plan

Apple (InlineKit):
1. Unit tests for per-bucket sequencing: out-of-order push followed by fetch must apply all seqs.
2. Unit tests for TOO_LONG: triggers repair path, does not fast-forward silently.
3. Unit tests for catch-up apply source: no notifications/unread inflation during catch-up.

Server:
1. Unit tests for `getUpdatesState` cursor behavior when there are no updates.
2. Unit tests for `getUpdates` TOO_LONG thresholds and invariants.

Manual:
1. Send messages while a client is offline, then reconnect.
2. Force a TOO_LONG scenario (large seq gap or fake) and verify client repairs by refetching history.
3. Verify UI status texts: no rapid "connecting" flicker in steady state.

## Rollout Plan

- Gate the high-risk changes behind feature flags: message catch-up enabled default; strict sequencer for push updates; TOO_LONG repair behavior.
- Start with macOS internal/beta, then iOS once stable.

## Open Questions

- Should catch-up be allowed to apply `.newMessage` at all, or should it always rely on history refetch for messages?
- What is the minimal repair action on TOO_LONG that guarantees message convergence without excessive data transfer?
