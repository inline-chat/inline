# macOS Burst Send Deep Investigation (Revised, 2026-02-26)

## Scope
- Re-audit burst-send regression after `c51bcf2a` and subsequent attempted fixes.
- Validate why previous optimizations did not produce meaningful gains.
- Focus only on macOS send hot path (`ComposeAppKit` -> realtime updates -> progressive VM -> `MessageListAppKit`).

## Bottom Line
The previous fixes were mostly secondary optimizations. The primary remaining regression driver is **send reconciliation fan-out**:
1. optimistic add
2. `updateMessageId` publish/update
3. `newMessage` publish/update

Each message still drives multiple expensive DB+UI reconciliation cycles, and those cycles still do heavy work in the message-list stack.

## What Changed vs Previous Report
Previous report correctly identified progressive metadata checks, but underweighted the larger still-active costs:
- duplicate post-send update publishes
- repeated `FullMessage` DB resolves per send
- repeated row reload + height invalidation per update event

These are still present and dominate under burst sends.

## Verified Current Send Pipeline

### 1) Send is optimistic
- `Realtime.send` runs `transaction.optimistic()` before queuing RPC.
- Files:
  - `apple/InlineKit/Sources/RealtimeV2/Realtime/Realtime.swift:341-354`
  - `apple/InlineKit/Sources/InlineKit/Transactions2/SendMessageTransaction.swift:164-236`

### 2) Server sends two self updates after optimistic add
- Ordered pair: `updateMessageId` then `newMessage`.
- File:
  - `server/src/functions/messages.sendMessage.ts:583-598`, `625-640`

### 3) Both updates currently publish message updates
- `UpdateMessageId.apply` saves message with `publishChanges: true`.
- `UpdateNewMessage.apply` saves message with `publishChanges: true`.
- File:
  - `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift:292-314`, `222-234`

### 4) Each publish resolves `FullMessage` again
- `MessagesPublisher.messageUpdated(...)` does `FullMessage.queryRequest().fetchOne(...)`.
- File:
  - `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift:770-793`

### 5) Each published update re-enters progressive/list update path
- Progressive VM update path still does id->index lookup by linear scan in update case.
- File:
  - `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift:188-201`

### 6) Message list applies row update + height invalidation per update event
- `.updated` path reloads rows and calls `noteHeightOfRows`.
- File:
  - `apple/InlineMac/Views/MessageList/MessageListAppKit.swift:1389-1403`

## Why Previous Fixes Showed Little Real Gain
The attempted fixes (dedupe map usage, metadata availability query reductions, partial row-item fast paths) reduced some overhead, but they did **not** remove the dominant multiplicative factor:
- still multiple update events per sent message
- still repeated full DB message resolution per update
- still repeated table row/height work per update

So the largest term in burst mode remained effectively unchanged.

## Root Cause Ranking (Revised)
1. **Reconciliation fan-out for self-sent messages** (optimistic + 2 post-send updates) in hot UI path.
2. **Per-update full message DB resolve** in `MessagesPublisher.messageUpdated`.
3. **Per-update list/layout invalidation** in `.updated` handling.
4. Secondary: progressive metadata/availability checks and add-path dedupe overhead.

## High-Impact Fix Order (Recommended)

### Fix 1: Collapse `updateMessageId` + `newMessage` to one publish for self-send pair
- If both are present in same applied batch, apply both DB mutations but publish once.
- Goal: drop post-send UI update count from 2 to 1.

### Fix 2: Remove redundant full-message fetch on intermediate ack stage
- Avoid resolving `FullMessage` twice for the same logical send reconciliation.

### Fix 3: Add O(1) id->index lookup for progressive `.update`
- Replace `firstIndex(where:)` scan in hot update path.

### Fix 4: Avoid row-height invalidation for ack-only updates
- For status/id-only updates, reload visible cell content without `noteHeightOfRows`.

## Measurement Plan (Must Do Before/After)
- Signpost durations for:
  - `UpdateMessageId.apply`
  - `UpdateNewMessage.apply`
  - `MessagesPublisher.messageUpdated`
  - `MessagesProgressiveViewModel.applyChanges(.update)`
  - `MessageListAppKit.applyUpdate(.updated)`
- Compare burst scenarios (10/20/50 sends) with same chat/history size.

## Risk Notes
- Coalescing publishes must preserve failure and resend correctness.
- Ack/new-message collapse should be gated to same-batch self-send pair only (safe narrow scope).
- Any height-invalidation skip needs guardrails to avoid stale layout on real content edits.

## Production Readiness Status
- Not production-ready yet for burst-send performance.
- Current branch has partial optimizations but misses primary reconciliation fan-out reduction.
