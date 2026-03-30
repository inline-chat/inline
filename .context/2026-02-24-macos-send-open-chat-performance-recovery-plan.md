# macOS Send/Open Chat Performance Recovery Plan (2026-02-24)

## Objective

Recover and harden macOS performance for:
1. Send message perceived latency.
2. Open chat time-to-interactive.
3. Jump/open reliability without regressions from history-window work.

## Performance budgets (must-pass)

1. Send tap -> optimistic message visible:
   - p50 <= 16ms
   - p95 <= 50ms
2. Open chat route -> first interactive frame (cached chat):
   - p50 <= 120ms
   - p95 <= 220ms
3. Open chat route -> first interactive frame (partial/empty cache):
   - p50 <= 200ms
   - p95 <= 350ms
4. No correctness regressions:
   - no duplicate rows
   - no lost rows
   - jump-to-message succeeds for uncached older targets

## Root causes to address

1. Progressive hot path still does avoidable O(n) mutation overhead (`messagesByID` full rebuild on every `messages` assignment).
2. Message list update path rebuilds row model too often (`applyUpdate` always calling full `rebuildRowItems`).
3. Text-only send path is non-optimistic on macOS (`ComposeAppKit` direct RPC path).
4. Chat-open startup includes non-critical work competing with first render.

## Execution plan

### Phase 1: Lock in measurement and regression guard

1. Add signposts/timers for:
   - send tap -> optimistic row visible
   - chat route start -> first interactive frame
   - applyUpdate duration (per change-set type)
   - rebuildRowItems duration/count per open session
2. Store baseline numbers for:
   - warm cache chat open
   - partial cache chat open
   - burst send (10 rapid messages)
3. Add a lightweight perf gate doc/checklist for PR review.

Acceptance:
1. Metrics available in logs/signposts and reproducible.
2. Baseline captured before further changes.

### Phase 2: Progressive VM hot-path optimization

1. Replace `messagesByID` full rebuild strategy with incremental index maintenance.
2. Separate metadata updates:
   - always: cheap message-id bounds update
   - conditional: local-availability DB checks only on pagination/refetch boundaries, never on every send/update.
3. Ensure add/update/delete paths are O(1) or O(k) where k = changed items.
4. Keep deterministic ordering behavior and existing tests intact.

Acceptance:
1. No DB availability query on ordinary `.add`/`.updated` event path.
2. Progressive ordering tests pass.
3. Send burst CPU time in progressive path drops materially versus baseline.

### Phase 3: MessageListAppKit incremental update model

1. Refactor `applyUpdate` so row model is updated structurally only when needed:
   - `.updated`: row-level reload only, no full row-model rebuild.
   - `.added`/`.deleted`: targeted row-model patch + insert/remove indices.
2. Eliminate unnecessary full `reloadData()` fallback for common append/prepend cases.
3. Keep scroll anchoring stable while avoiding redundant `scrollToBottom` calls.

Acceptance:
1. `rebuildRowItems` count per send burst is near zero for non-structural updates.
2. No visual regressions in day separators and grouping.
3. Open-chat and send p95 improve vs baseline.

### Phase 4: Restore optimistic text-only send UX

1. Route text-only sends through optimistic transaction flow on macOS.
2. Keep current ack/failure reconciliation semantics.
3. Preserve silent-send and entity behavior.

Acceptance:
1. Message appears immediately on tap under normal conditions.
2. Failure state still transitions correctly.
3. No duplicate optimistic+server rows.

### Phase 5: Defer non-critical chat-open work

1. Defer translation detection/analysis until after first interactive frame.
2. Defer optional side tasks (integration checks, non-essential unread work) out of first-frame critical path.
3. Coalesce duplicate open-time refetch triggers.

Acceptance:
1. First-frame metrics improve without feature loss.
2. Deferred tasks still complete and update UI correctly.

### Phase 6: Complete pending Part 5 integration safely

1. Finish unified jump pipeline:
   - in-window
   - local around-target
   - remote around-target
2. Integrate bidirectional edge loading post-jump with strict in-flight guards.
3. Keep spinner gating tied to auth+connected+in-flight only.

Acceptance:
1. Far uncached jumps succeed reliably.
2. No paging dead-ends after jump.
3. No blocking spinner when offline/disconnected.

## Validation matrix

1. Focused checks:
   - `cd apple/InlineKit && swift build`
   - `cd apple/InlineKit && swift test --filter FullChatProgressive`
2. Manual:
   - open warm-cache chat repeatedly
   - open partial-cache chat and paginate older/newer
   - send 10 rapid text messages
   - reply/pinned/forward jump to old uncached message
3. Compare each phase against baseline budgets.

## Rollout and risk control

1. Ship in narrow commits per phase.
2. Guard risky behavior with temporary feature flags where needed.
3. If regression appears, roll back only the latest phase commit (not full history-window work).

## Production readiness criteria

1. All budgets pass on target macOS hardware test set.
2. No correctness regressions in pagination/jump behavior.
3. No new security-sensitive surface introduced (performance/path orchestration only).
