# macOS: Message Send Latency (Optimistic Send) (2026-02-07)

From notes (Feb 5, 2026): "message send speed on macOS sucks".

## Goal

Make sent messages appear immediately in the UI with a clear “sending” state, without waiting for the server roundtrip.

## Hypothesis (High Confidence)

macOS compose currently sends text-only messages via a direct realtime RPC, and does not insert an optimistic local message row first. That makes the UI wait for the server echo/update to render the message, which feels slow on normal latency.

Relevant code:
- macOS send path: `apple/InlineMac/Views/Compose/ComposeAppKit.swift`

Evidence:
1. Text-only send uses `Api.realtime.send(.sendMessage(...))`.
2. The older Transactions-based path is commented out.
3. Attachment sends still use `Transactions.shared.mutate(.sendMessage(TransactionSendMessage(...)))`.

## Spec

### 1. Restore optimistic send for text-only messages on macOS

Approach options:

Option A (Recommended): use the same Transactions-based pipeline for text-only.
1. Always call `Transactions.shared.mutate(.sendMessage(TransactionSendMessage(...)))`.
2. Let the transaction layer create a local “sending” message, then reconcile on server response.

Option B: keep direct RPC but insert local pending message first.
1. Create a local Message row with status `.sending`.
2. On success, update with server message id/global id.
3. On failure, mark `.failed` and allow retry.

### 2. Reconciliation rules

1. If the server sends the same message back, match it to the local optimistic message and replace in-place.
2. Ensure the message list doesn’t show duplicates.

### 3. Failure UX

1. If send fails, keep the message bubble with a failed indicator and a retry action.
2. Retrying should reuse the same local message row if possible.

## Implementation Plan

1. Identify the existing optimistic-send behavior in the Transactions layer.
2. Switch macOS text-only send back to Transactions-based send (Option A).
3. Validate reconciliation logic:
4. No duplicates on success.
5. Correct order in the message list.

4. Add a small latency metric:
5. Time from Return keypress to message visible.
6. Time to “sent” state.

## Testing Checklist

1. Normal network: message appears instantly and transitions to sent.
2. Slow network (throttle): message appears instantly, stays “sending” longer.
3. Offline: message becomes failed and can retry.
4. Attachment send remains correct.

## Acceptance Criteria

1. Text-only send feels instant on macOS.
2. No duplicate messages appear on reconciliation.
3. Failure state is visible and recoverable.

