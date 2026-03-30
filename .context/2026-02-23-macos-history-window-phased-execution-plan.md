# macOS History Window Phased Execution Plan (2026-02-23)

Status: Active execution tracker.
Source of truth for rollout and release gating.

## Executive summary

- We completed foundational and backend-enabling slices (Parts 1-4) and intentionally left final jump/orchestration UX completion for Part 5.
- The backend now supports explicit history modes on the same RPC contract (`GetChatHistoryInput`) with legacy `offset_id` compatibility.
- Client now has local around-target loading, reason-aware jump events, and remote older backfill when local cache is exhausted.
- Not production-complete for the full requested experience yet; unread separator/anchor-first open behavior and complete jump UX finalization remain.

## Current production status

- Completed and integrated:
  - Part 1: progressive VM refactor + invariants
  - Part 2: local window/gap scaffolding + reason-aware jump plumbing
  - Part 3: explicit remote history API modes (single RPC path)
  - Part 4: remote older-edge backfill path in macOS list flow
- Remaining before feature-complete:
  - Part 5: end-to-end jump-to-message completion and bidirectional load integration
  - Unread separator and initial anchor placement behavior still pending
  - Spinner gating tied to realtime connection/auth/in-flight status still pending

## Release scope and commit plan

To reduce risk and keep rollback simple, release as incremental commits in this order:

1. Client foundations (Parts 1-2): progressive VM + local jump scaffolding.
2. Server/proto contract + backend modes (Part 3): explicit mode API and tests.
3. Client remote edge backfill (Part 4): remote older fill when local cache is exhausted.
4. (Next release) Part 5 only.

Each commit must stay scoped to the files for that part and pass targeted checks below.

## Validation and rollout gates

Required checks before production push for completed parts:

1. InlineKit targeted tests:
   - `swift test --filter MessagesProgressiveViewModelOrderingTests`
   - `swift test --filter MessagesSectionedViewModelOrderingTests`
2. Server history API:
   - `bun test src/__tests__/functions/getChatHistory.test.ts`
   - `bun run typecheck`
3. Manual smoke (post-deploy recommended):
   - open chat with partial cache
   - scroll to top until local cache ends and confirm older remote fill continues
   - reply/pinned/forwarded jump to locally cached old messages

Known limitation: no full `xcodebuild` was run as part of this execution.

## Scope and locked decisions

Context:

- Target platform: macOS new UI only (shared internals may still be touched).
- Primary surfaces: chat open, message list pagination, jump-to-message flows (reply/pinned/chat-info go-to), unread anchor behavior.

Locked product/technical decisions:

1. Use `GetChatHistoryInput` as the single history RPC contract host.
2. Use explicit query mode semantics (not Telegram-style ambiguous offset combinations):
   - `older(before_id, limit)`
   - `newer(after_id, limit)`
   - `around(anchor_id, before_limit, after_limit, include_anchor)`
   - optional `latest(limit)`
3. Unread manual mark (`unreadMark == true` with `unreadCount == 0`) does not create unread separator/anchor.
4. Unread anchor visual placement is near top with padding.
5. Gap strategy defaults to lazy fill.
6. Spinner blocks only while logged-in + connected + fetch in-flight; offline/disconnected does not block with spinner.
7. Future chat open precedence (when saved scroll ships): explicit target -> saved position -> unread anchor -> latest.

## Current architecture constraints (verified)

1. `MessagesProgressiveViewModel` is date-cursor based today and local DB only (`apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift`).
2. `MessageListAppKit.loadBatch(at:)` only supports `.older` despite shared enum having `.newer` (`apple/InlineMac/Views/MessageList/MessageListAppKit.swift`).
3. `scrollToMsgAndHighlight` retries older local batches only; no remote around-target jump path.
4. `ChatViewAppKit` mounts cached list quickly when chat exists; spinner is currently only coarse `.loading` state.
5. Server `getChatHistory` supports `offsetId` (`messageId < offset`) + `limit` only (`server/src/functions/messages.getChatHistory.ts`).
6. Server already has `MessageModel.getMessagesAroundTarget(...)`, but it excludes anchor row and is not wired to chat history RPC path.

## Rollout strategy (deployable slices)

We will ship in five parts so each deployment is low risk and self-contained.

## Execution tracker

- Part 1: Completed
- Part 2: Completed
- Part 3: Completed
- Part 4: Completed
- Part 5: Planned (not started)

## Execution log

- 2026-02-23: Started Part 1 (surgical refactor + invariants).
- 2026-02-23: Refactored `MessagesProgressiveViewModel` internals into dedicated helpers for:
  - load request construction
  - query construction/fetch for base and additional loads
  - deterministic batch dedupe/merge
  - range recomputation
- 2026-02-23: Added scoped trace logs for:
  - load mode (`limit` vs `preserveRange`)
  - load direction and batch dedupe counts (raw vs deduped)
- 2026-02-23: Added Part 1 tests in `FullChatProgressiveTests` for:
  - cursor-boundary dedupe behavior
  - deterministic prepend/append merge order
- 2026-02-23: Validation:
  - `swift test --filter MessagesProgressiveViewModelOrderingTests` passed.
  - Full `swift test` run hit existing flakiness in `RealtimeV2.RealtimeStateDisplay` when run with full suite.
  - `swift test --filter RealtimeStateDisplayTests` passed when isolated.
- 2026-02-23: Started and completed Part 2 (client-side window/gap scaffolding, local-first).
- 2026-02-23: Added local window metadata in `MessagesProgressiveViewModel`:
  - `oldestLoadedMessageId`
  - `newestLoadedMessageId`
  - `canLoadOlderFromLocal`
  - `canLoadNewerFromLocal`
- 2026-02-23: Added gap-range scaffolding in `MessagesProgressiveViewModel`:
  - `MessageGapRange`
  - gap merge helper `mergedGapRanges`
  - state mutators for set/add/clear
- 2026-02-23: Added local around-target loading in progressive VM:
  - `loadLocalWindowAroundMessage(messageId:)`
  - rebuilds in-memory window from local DB around target ID without remote dependency
- 2026-02-23: Extended chat scroll event payload to include reason metadata:
  - `ScrollToMessageRequest`
  - `ScrollToMessageReason` (`reply`, `pinned`, `forwarded`, `media`, `link`, `search`, `unknown`)
- 2026-02-23: Wired reason-aware jump dispatch at existing entry points:
  - embedded/reply and pinned header tap
  - forwarded-message header tap (regular and minimal message views)
- 2026-02-23: Updated message list jump behavior:
  - first attempt local around-target window load
  - fallback to older local batch load only when local metadata indicates availability
  - uncached targets continue to fail gracefully (no remote fetch in Part 2)
- 2026-02-23: Part 2 validation:
  - `swift test --filter MessagesProgressiveViewModelOrderingTests` passed after Part 2 changes.
  - Added test coverage for gap-range merge behavior in `FullChatProgressiveTests`.
- 2026-02-23: Started and completed Part 3 (single-RPC explicit remote history modes).
- 2026-02-23: Expanded `GetChatHistoryInput` in `proto/core.proto` with explicit mode fields:
  - `mode` (`latest`, `older`, `newer`, `around`)
  - `anchor_id`, `before_id`, `after_id`
  - `before_limit`, `after_limit`, `include_anchor`
  - kept legacy `offset_id` behavior for backward compatibility
- 2026-02-23: Regenerated protocol artifacts:
  - `packages/protocol/src/core.ts`
  - `apple/InlineKit/Sources/InlineProtocol/core.pb.swift`
- 2026-02-23: Implemented mode-aware server behavior:
  - `latest`: newest messages
  - `older`: cursor before `before_id` (or legacy `offset_id`)
  - `newer`: cursor after `after_id`
  - `around`: centered fetch around `anchor_id` with optional anchor inclusion
- 2026-02-23: Ensured around-mode anchor inclusion guarantee (`include_anchor` defaults true).
- 2026-02-23: Added request validation in function/handler for invalid mode-field combinations.
- 2026-02-23: Added/updated backend tests in `server/src/__tests__/functions/getChatHistory.test.ts` for:
  - explicit newer mode
  - around mode with include/exclude anchor
  - invalid explicit mode combinations
- 2026-02-23: Part 3 validation:
  - `cd /Users/mo/dev/inline/server && bun test src/__tests__/functions/getChatHistory.test.ts` passed.
  - `cd /Users/mo/dev/inline/server && bun run typecheck` passed.
- 2026-02-23: Started and completed Part 4 (remote backfill when local cache edge is exhausted).
- 2026-02-23: Implemented macOS remote older-history backfill in message list flow:
  - when top-edge local load returns no rows and local cache has no older rows, request remote older batch
  - after remote save, re-run local batch load so inserted rows are anchored without jump
  - track “no more remote older before X” boundary to avoid redundant repeated RPCs
  - prevent duplicate in-flight remote older requests for the same cursor
- 2026-02-23: Part 4 validation:
  - `cd /Users/mo/dev/inline/apple/InlineKit && swift test --filter MessagesProgressiveViewModelOrderingTests` passed (post-proto regeneration and client changes).
  - Note: app-target compile for `InlineMac` UI files was not run (no full `xcodebuild`).

## What is left (detailed)

1. Part 5: proper jump-to-message + bidirectional integration
   - unify jump pipeline: in-window -> local around-target -> remote around-target fallback
   - ensure highlight/scroll only after target availability is confirmed
   - extend runtime paging path so both older and newer edges can be filled consistently after jumps
2. Unread UX and initial open behavior
   - unread separator row placement near top with padding
   - initial scroll anchor to unread target when no higher-priority explicit/saved target exists
   - skip unread anchor when `unreadMark == true` and `unreadCount == 0` (already locked as requirement)
3. Loading state UX hardening
   - spinner should block only when authed + connected + fetch in-flight
   - offline/disconnected should avoid blocking spinner and stale-content confusion
4. Saved-position compatibility work
   - enforce precedence chain: explicit target -> saved position -> unread anchor -> latest
   - avoid regressions when saved-position feature lands
5. Manual and integration validation
   - deep jump scenarios (pinned/media/reply/go-to)
   - empty/partial cache boundary behavior in both directions
   - around-target with large historical gaps

## Risks and mitigations

1. Mixed in-flight UI refactors in message list files
   - Risk: accidental coupling with ongoing minimal-style work.
   - Mitigation: scope commits to feature-specific hunks/files and keep release commits incremental.
2. API contract expansion complexity
   - Risk: invalid mode parameter combinations or client/server mismatch.
   - Mitigation: explicit handler validation + dedicated function tests + generated protocol artifacts in same release.
3. Scroll anchoring regressions
   - Risk: jump jitter or wrong row anchoring after remote insert.
   - Mitigation: preserve existing anchor maintenance path and validate with manual smoke before/after push.
4. Data window consistency
   - Risk: duplicate or skipped rows during local/remote merges.
   - Mitigation: stable sorting and dedupe invariants already covered; keep additional merge tests as Part 5 expands.

## Next-step implementation sequence

1. Ship commits for completed Parts 1-4 (this checkpoint).
2. Run production smoke on top-edge remote fill and local jump cases.
3. Implement Part 5 in a dedicated scoped commit set.
4. Run same checks + added manual jump cases, then push final feature completion.

---

## Part 1: Surgical refactor + invariants (no behavior change)

Goal:

- Prepare `MessagesProgressiveViewModel` for future cursor/gap work without changing runtime behavior.

Deliverables:

1. Refactor internals into clear units (private helpers/types only):
   - query building
   - batch merge/dedupe
   - range tracking updates
   - changeset emission path
2. Keep current date-based cursor behavior intact.
3. Expand focused tests around existing guarantees.
4. Add minimal logging/metrics hooks for batch load decisions (no product-visible change).

Primary files:

- `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift`
- `apple/InlineKit/Tests/InlineKitTests/FullChatProgressiveTests.swift`
- `apple/InlineKit/Tests/InlineKitTests/MessagesSectionedViewModelTests.swift` (only if required for contract preservation)

Acceptance criteria:

1. No UI behavior regression on current chat open/scroll.
2. Existing message ordering remains deterministic.
3. Existing unit tests pass; new tests pass.
4. No API/proto/server change yet.

Suggested verification:

1. `cd /Users/mo/dev/inline/apple/InlineKit && swift test`

Deployment risk:

- Low.

Implementation sequence (file-level):

1. `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift`
   - Extract private query helpers to isolate the two current SQL patterns:
     - initial/range load query (`loadMessages`)
     - additional batch query (`loadAdditionalMessages`)
   - Extract private merge helpers:
     - date-cursor dedupe rule at cursor boundary
     - prepend/append merge path
   - Extract private range helpers:
     - range recomputation
     - cursor selection for `loadBatch(at:)`
   - Keep all public API and behavior unchanged.
2. `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift`
   - Add scoped trace points around:
     - load mode (`limit` vs `preserveRange`)
     - load direction (`older`/`newer`)
     - batch size before/after dedupe
3. `apple/InlineKit/Tests/InlineKitTests/FullChatProgressiveTests.swift`
   - Add focused tests for:
     - stable ordering tie-breakers (already covered, preserve)
     - cursor-boundary dedupe behavior
     - deterministic insert location for prepend/append helper
4. Optional only if needed:
   - `apple/InlineKit/Tests/InlineKitTests/MessagesSectionedViewModelTests.swift`
   - Update only if shared ordering helper signatures move.

Non-goals for Part 1:

1. No unread separator UI changes.
2. No jump pipeline behavior change.
3. No server/proto/API changes.

Exit gate to start Part 2:

1. `swift test` in `apple/InlineKit` passes.
2. No call-site signature changes required outside `InlineKit`.
3. Manual smoke in macOS chat confirms no visible pagination regression.

---

## Part 2: Client-side window/gap scaffolding (still local-first)

Goal:

- Introduce message-window and gap model primitives on client side, still without relying on new remote history modes.

Deliverables:

1. Add window state model in progressive VM:
   - `oldestLoadedMessageId`
   - `newestLoadedMessageId`
   - local edge availability flags
2. Add gap-range data structure and merge rules (metadata only in this part).
3. Add local around-target load path for jump plumbing:
   - if target exists in DB but outside visible window, rebuild window around target using local DB query path.
4. Add jump request plumbing with reason metadata (reply/pinned/forwarded/media/link/search) from macOS entry points.
5. Keep current fallback behavior for truly uncached targets (no new remote mode yet).
6. Gate all new behavior to new UI path only where applicable.

Primary files:

- `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift`
- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`
- `apple/InlineMac/Views/Chat/State/ChatState.swift` (if jump payload shape is extended)
- `apple/InlineMac/Views/EmbeddedMessage/EmbeddedMessageView.swift`
- `apple/InlineMac/Views/Message/MessageView.swift`
- `apple/InlineMac/Views/MessageList/PinnedMessageHeaderView.swift` (if jump reason/source hook added)

Acceptance criteria:

1. Existing chat behavior remains stable in normal open/scroll.
2. Jump to message improves for locally-cached-but-not-loaded targets.
3. No remote API dependency introduced yet.
4. Jump reasons can be traced in logs for diagnostics.

Suggested verification:

1. `cd /Users/mo/dev/inline/apple/InlineKit && swift test`
2. Manual macOS checks:
   - reply tap jump
   - pinned header jump
   - forwarded header jump
   - no regressions in plain scroll and compose interactions

Deployment risk:

- Low to medium (touches list control flow, but no server/proto coupling yet).

Implementation sequence (file-level):

1. `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift`
   - Introduce internal window metadata state:
     - `oldestLoadedMessageId`
     - `newestLoadedMessageId`
     - `canLoadOlderFromLocal`
     - `canLoadNewerFromLocal`
   - Keep current date-based loading as source of truth for this phase.
2. `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift`
   - Introduce internal gap metadata type (no remote fill yet):
     - message-id ranges marked unknown/missing
     - deterministic merge of overlapping ranges
3. `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift`
   - Add local around-target load path:
     - query DB around a target message ID
     - rebuild in-memory message window from that local subset
     - emit reload changeset for consistency
4. `apple/InlineMac/Views/Chat/State/ChatState.swift`
   - Extend scroll event payload from plain message ID to a request object with:
     - target message ID
     - source reason (`reply`, `pinned`, `forwarded`, `media`, `link`, `search`, `unknown`)
5. Jump entry points:
   - `apple/InlineMac/Views/EmbeddedMessage/EmbeddedMessageView.swift`
   - `apple/InlineMac/Views/Message/MessageView.swift`
   - `apple/InlineMac/Views/MessageList/PinnedMessageHeaderView.swift`
   - Pass reason metadata when dispatching jump requests.
6. `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`
   - Replace recursive “load older until found” loop with:
     - local around-target request via progressive VM
     - fallback to current behavior only when local target absent
   - Keep batch direction behavior unchanged in this part (`.older` only at runtime).

Non-goals for Part 2:

1. No new remote history mode usage.
2. No spinner-state redesign yet.
3. No bidirectional remote paging yet.

Exit gate to start Part 3:

1. Local-cached far target jumps without recursive top-only batch loading.
2. Uncached far target still fails gracefully without stale-list corruption.
3. Jump reason metadata visible in logs from all wired entry points.
4. `swift test` for `InlineKit` passes and manual macOS jump flows pass.

---

## Part 3: Add new remote history API modes (single RPC path)

Goal:

- Extend `getChatHistory` contract with explicit mode semantics.

Deliverables:

1. Proto updates in `GetChatHistoryInput` to represent explicit mode.
2. Server function + handler wiring to parse mode and route to correct query shape.
3. Keep old `offset_id` compatibility during migration.
4. Ensure around-mode includes anchor row.
5. Add/extend backend tests for mode behavior and cursor invariants.
6. Regenerate protocol artifacts.

Primary files:

- `proto/core.proto`
- `server/src/functions/messages.getChatHistory.ts`
- `server/src/realtime/handlers/messages.getChatHistory.ts`
- `server/src/db/models/messages.ts`
- `server/src/__tests__/functions/getChatHistory.test.ts`
- generated protocol outputs (via repo script)

Acceptance criteria:

1. Older/newer/around modes all return deterministic, non-overlapping pages.
2. Anchor row inclusion is guaranteed for around mode.
3. Legacy callers using old fields continue to function.

Suggested verification:

1. `cd /Users/mo/dev/inline && bun run generate:proto`
2. `cd /Users/mo/dev/inline/server && bun test src/__tests__/functions/getChatHistory.test.ts`

Deployment risk:

- Medium (contract and server behavior change).

---

## Part 4: Remote backfill when local window has gap/runs out

Goal:

- When local cache is insufficient at either edge, fetch from remote and continue seamlessly.

Deliverables:

1. Wire progressive VM + message list to call remote modes when local edge is exhausted.
2. Apply lazy gap-fill strategy:
   - mark missing ranges
   - fill when viewport approaches or jump depends on it
3. Preserve scroll stability on inserted pages.
4. Keep retry semantics compatible with RealtimeV2 queueing behavior.

Primary files:

- `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift`
- `apple/InlineKit/Sources/InlineKit/Transactions2/GetChatHistoryTransaction.swift`
- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`

Acceptance criteria:

1. Scrolling up/down continues even with clear/partial cache.
2. No duplicate rows when batches merge.
3. Gaps converge as user navigates without hard-reset by default.

Deployment risk:

- Medium to high (live pagination behavior changes).

---

## Part 5: Proper jump-to-message + bidirectional load integration

Goal:

- Fully reliable jumps for old uncached targets without loading full intermediate history.

Deliverables:

1. Unified target jump pipeline:
   - local current window
   - local DB around-target
   - remote around-target fallback
2. Scroll/highlight only after target availability is confirmed.
3. Post-jump, rely on bidirectional edge pagination.
4. Spinner gating tied to realtime connection/auth + in-flight fetch only.

Primary files:

- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`
- `apple/InlineMac/Views/ChatView/ChatViewAppKit.swift`
- `apple/InlineMac/Views/Chat/State/ChatState.swift`
- jump entry point views (embedded/pinned/message/chat-info surfaces)

Acceptance criteria:

1. Reply/pinned/chat-info jumps work for far-older uncached targets.
2. No full replay of intermediate history.
3. Offline behavior avoids blocking spinner.

Deployment risk:

- Medium (user-visible jump flow changes).

---

## Cross-part testing matrix

1. Unit:
   - ordering invariants
   - cursor boundaries
   - dedupe and merge behavior
   - gap-range merge logic
2. Backend:
   - explicit mode semantics in `getChatHistory` tests
3. Manual macOS new UI:
   - open large chat with partial cache
   - top and bottom edge pagination
   - pinned/reply/forward/chat-info jump to old message
   - unread/read badge behavior not regressing

## Security / attack surface notes

1. History mode expansion increases query-surface complexity; validate all mode inputs server-side and reject invalid combinations.
2. Keep existing access guard checks (`AccessGuards.ensureChatAccess`) unchanged in all new query branches.
3. Ensure no plaintext user content handling changes; keep encryption-at-rest path untouched.

## Production readiness checkpoint policy

1. Part 1: expected production-safe.
2. Part 2: expected production-safe with focused manual verification.
3. Parts 3-5: require stronger regression validation before production rollout.

## Immediate next action

Start Part 1 only (no behavior change), then report diff and test results before moving to Part 2.
