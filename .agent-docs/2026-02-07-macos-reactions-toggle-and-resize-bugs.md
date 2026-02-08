# macOS: Reactions Toggle + Resize Bugs (2026-02-07)

From notes (Feb 7, 2026): "fix: click on reaction does not remove it (ben)", "fix: on resize reactions are not positioned correctly (ben)".

## Goals

1. Clicking a reaction chip toggles the current user’s reaction reliably (add removes, remove removes).
2. Reactions layout stays aligned during and after window resize.
3. Double click behavior is either correct or removed (no broken hidden features).

## Current State (Relevant Code)

1. Reaction chips are AppKit buttons in `MessageReactionsView`.
2. Chip click toggles reaction by checking whether the current user is in the grouped reaction list.
3. Message view also has a double-click gesture that toggles a hard-coded emoji ("✔️") using a buggy `weReacted` check.

Key files:
- Chips + toggle: `apple/InlineMac/Views/Reactions/MessageReactionsView.swift`
- Double click handler + constraints: `apple/InlineMac/Views/Message/MessageView.swift`
- Layout plans: `apple/InlineMac/Views/MessageList/MessageSizeCalculator.swift`
- Resize recalc: `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`

## Known Bug (High Confidence): Double Click Reaction Logic

In `MessageViewAppKit.handleDoubleClick`:
1. `weReacted` is computed as "user reacted with any emoji", not "user reacted with the target emoji".
2. Emoji is hard-coded to "✔️".

This causes incorrect toggling when the user has reacted with a different emoji.

## Plan

### Phase 0: Make broken behavior impossible

Pick one:
1. Disable double-click reaction entirely until it is correctly designed.
2. Fix it correctly (see Phase 1).

### Phase 1: Fix double-click reaction correctly (if we keep it)

1. Choose a single default emoji for double click (example: "✔️" or "👍").
2. Compute `weReacted` only for that emoji group.
3. Delete or add exactly that emoji.

Touchpoint:
- `apple/InlineMac/Views/Message/MessageView.swift`

### Phase 2: Fix chip-click “does not remove” bug (investigate + patch)

We need to disambiguate whether the bug is:
1. Click handler not firing.
2. Server delete/add not succeeding.
3. Local update not applied (UI not reloading grouped reactions).
4. Emoji normalization mismatch (variation selectors, skin tones).

Instrumentation plan (temporary, DEBUG):
1. In `handleChipClick`, log:
2. messageId/chatId, emoji, currentUserId, computed `weReacted`.
3. Count of reactions in the group before and after.
4. RPC result error if thrown.

Likely fixes:
1. Normalize emoji comparison using a canonical form when comparing and sending.
2. Ensure UI updates re-fetch `FullMessage` after reaction updates (it should via `MessagesPublisher`, verify no missed path).
3. If server sends delete update even when DB delete fails, add server-side verification or return a meaningful error (optional).

### Phase 3: Resize positioning bug

Two behaviors to decide on:
1. During live resize, it is acceptable for layout to be imperfect, but it must settle correctly at end.
2. If we want it correct during live resize, we need throttled layout recompute for visible rows.

Plan A (Low risk): correctness after resize end
1. Verify `MessageListAppKit` live-resize-end recalculation updates visible rows.
2. Ensure `rowView.updateSizeWithProps` triggers reaction chip relayout without animations during resize settle.
3. If reactions still misalign after resize end, force a `reactionsView.update(... animate: false)` when width changes.

Plan B (Better UX): throttled updates during live resize
1. Add a throttled `recalculateHeightsOnWidthChange(duringLiveResize: true)` for visible rows only.
2. Disable reaction chip animations during live resize.

Touchpoints:
- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`
- `apple/InlineMac/Views/Message/MessageView.swift`

## Testing Checklist

1. Add reaction, then click again to remove. Verify the chip state updates immediately.
2. Add a different emoji reaction, then use double-click (if enabled). Verify it toggles the intended emoji only.
3. Resize the window during a message with many reactions:
4. During live resize: acceptable minor mismatch (if Plan A).
5. After resize ends: chips aligned with bubble and hit testing correct.

## Acceptance Criteria

1. Chip click toggles reliably for at least 20 consecutive toggles without desync.
2. No broken double-click behavior remains.
3. After resize end, reaction layout is correct.

## Open Questions

1. Do we want double-click to react at all, or should it open the reaction overlay instead?
2. Should reactions be allowed outside bubble in all cases, or only when non-bubble layout is enabled?

