# Pinned Messages: Stable Fetch + Navigate + Flicker Fix (2026-02-07)

From notes (Feb 4-7, 2026): "pin needs stable fetch and navigate to item", "fix pinned message flicker".

Related existing doc:
- `/.agent-docs/2026-02-01-pinned-messages-plan.md`

## Goals

1. Pinned header does not flicker during sync/update churn.
2. Tapping a pinned message reliably navigates to it (even if it is not locally loaded).
3. The pinned list is stable and ordered.

## Current State (Relevant Code)

Local DB:
1. Pinned messages are stored in `pinnedMessage` table.
2. Pinned messages are also represented on `Message.pinned` and `Dialog.pinned` for other UI uses.

Update application:
1. Pinned messages updates are applied in `InlineKit` update apply code.
2. `GetChatTransaction` also saves `pinnedMessageIds` into `pinnedMessage` table.

macOS pinned header UI:
1. `PinnedMessageHeaderView` observes the first pinned message for a chat and loads its `FullMessage`.
2. It animates visibility changes (fade in/out).

Key files:
- Apply updates: `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift`
- Initial save on get chat: `apple/InlineKit/Sources/InlineKit/Transactions2/GetChatTransaction.swift`
- Pinned header view: `apple/InlineMac/Views/MessageList/PinnedMessageHeaderView.swift`

## Likely Flicker Mechanisms

1. The pinned message ID transiently changes to nil and back (DB update pattern or multiple updates).
2. The header view responds by animating hide/show rather than updating content in-place.
3. Even without nil transitions, frequent reconfiguration can look like flicker if it resets content state.

## Spec: Make Pinned Header Stable

### 1. Avoid hide/show for “ID changed”

Behavior:
1. If pinned message ID changes from A to B, keep the header visible and crossfade content.
2. Only hide when there are truly no pinned messages.

Implementation idea:
1. Split “visibility state” from “content state”.
2. For content changes, update `embedView` without calling `setVisible(false)` first.

Touchpoint:
- `apple/InlineMac/Views/MessageList/PinnedMessageHeaderView.swift`

### 2. Coalesce pinned message observation events

If the DB produces transient nil states:
1. Debounce the observation updates slightly (example: 50-100ms).
2. Apply `removeDuplicates` for messageId.

This reduces flicker while preserving correctness.

### 3. Make “Pinned message unavailable” non-jarring

If the pinned message is not in local DB:
1. Show a stable placeholder state without collapsing the header.
2. Attempt a remote fetch around the pinned message ID (see go-to-message spec).

## Spec: Navigate To Pinned Message

### User action

1. Clicking the pinned header opens a pinned details view or scrolls directly to the pinned message.
2. Recommended: scroll directly (fast path), with a fallback to a pinned list UI if multiple pins exist.

### Data behavior

1. If message exists locally, scroll immediately.
2. If not, request remote backfill around messageId and then scroll.

This depends on:
- `/.agent-docs/2026-02-07-chat-open-perf-pagination-go-to-message.md`

## Implementation Plan

### Phase 1: Header stability

1. Add “content crossfade” behavior for ID changes.
2. Add coalescing/debouncing if needed.
3. Ensure no header height jitter during updates.

### Phase 2: Navigate

1. Add click handler to pinned header.
2. Implement scroll-to-message integration with chat state.
3. Add remote backfill call when needed.

### Phase 3: Multiple pins

1. If multiple pinned messages exist, add a pinned list UI with up/down navigation.
2. Keep header showing the “current pin” with a count indicator.

## Testing Checklist

1. Pin/unpin rapidly: header should not flicker or collapse incorrectly.
2. Sync catch-up: pinned header should remain stable while updates apply.
3. Click pinned header:
4. If local: scrolls to message.
5. If remote: loads around and scrolls, no crash.

## Acceptance Criteria

1. No visible pinned header flicker during normal usage and reconnect.
2. Navigate-to-pin works even when pinned message is not already loaded.

## Open Questions

1. Do we want pinned header to show the first pin only, or support cycling through pins?
2. Should pinned navigation open a dedicated pinned panel on macOS?

