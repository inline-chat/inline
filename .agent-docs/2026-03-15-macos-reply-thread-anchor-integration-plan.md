# macOS Reply-Thread Anchor Integration Plan

Date: 2026-03-15
Status: proposed

## Problem

The reply-thread anchor row on macOS is not integrated into the normal message-list model.

Today it is maintained as side-state in `MessageListAppKit`:

- `replyThreadAnchorMessage` is observed separately from `MessagesProgressiveViewModel`
- the table row switches between a placeholder `ReplyThreadAnchorTableCell` and a real `MessageTableCell`
- `reloadReplyThreadAnchorRow()` directly calls `noteHeightOfRows` + `reloadData(forRowIndexes:)`

That causes visible height instability because AppKit sees the row height jump from placeholder height to message-calculated height outside the normal list update pipeline.

## Root Cause

The anchor is currently a special-case row, not a first-class timeline item.

As a result it bypasses:

- the main diff/update path in `MessagesProgressiveViewModel`
- row identity and row update batching
- background height precalculation
- visible-row height recalculation
- message-list cache helpers that are keyed by normal message rows
- translation/update handling used for the main message list

This creates two classes of bugs:

1. initial placeholder -> real-message height jump
2. later re-layout drift when translation, width, or message-derived layout changes occur

## Fix Direction

Make the anchor and the `Replies` separator real timeline items owned by the list/view-model layer, not ad hoc controller state.

## Proposed Model

Add a first-class timeline item model for the macOS message list:

- `.replyThreadAnchor(FullMessage?)`
- `.replyThreadSeparator`
- `.daySeparator(Date)`
- `.message(FullMessage)`

Important:

- the anchor item must have a stable synthetic identity, for example `reply-anchor:<chatId>:<parentMessageId>`
- the separator item must also have a stable identity
- normal messages keep their existing stable ids

## Data Flow

### Phase 1: Move anchor state into the view model

Extend `MessagesProgressiveViewModel` or a small wrapper timeline view model to expose:

- `messages`
- `replyThreadAnchorMessage`
- computed `timelineItems`

The list controller should render only `timelineItems`.

The controller should stop owning:

- `replyThreadAnchorMessage`
- `replyThreadAnchorObservation`
- `hasRequestedReplyThreadAnchorFetch`

### Phase 2: Unify fetch/observe logic

Anchor loading should be part of the same data source contract as the rest of the thread:

- seed from `GetChatResult.anchorMessage` when available
- observe the stored anchor message from the view-model/data layer
- if missing locally, request caching through a view-model-owned fetch path

The list should react to a normal published state change, not call table-row reload methods directly from a side observation.

### Phase 3: Render anchor with the normal message-cell path

Keep using `MessageTableCell` for the anchor row, but configure it through the same row-item renderer used for normal messages:

- bubble/minimal render style stays shared
- `showsReplyThreadFooter = false`
- synthetic `firstInGroup / isFirstMessage / isLastMessage` stays deterministic

The placeholder state, if still needed, should also be represented as the anchor timeline item state rather than as a different row class.

## Height / Layout Plan

Once the anchor becomes a timeline item:

- `heightOfRow` should resolve from the same item model path as all other rows
- width-change recalculation should include anchor rows
- background precalculation should include anchor rows
- translation-triggered reloads should include anchor rows
- update batching should decide whether to reload the anchor row with animation or not

For the anchor specifically:

- initial placeholder -> loaded message transition should be non-animated
- later content-only updates should usually be non-animated as well

## Recommended Implementation Order

1. Introduce `TimelineRowItem` with stable ids and anchor/separator cases.
2. Move anchor observation/fetch into the view-model layer.
3. Make `MessageListAppKit` consume only timeline items.
4. Remove `ReplyThreadAnchorTableCell` as a separate row type once placeholder rendering is supported through the normal row model.
5. Teach height precalc / visible-row resize / translation reload paths to include the anchor item.
6. Only after that, tune any remaining row animation behavior.

## Expected Result

This should eliminate the unstable height animation because:

- the anchor row will no longer hot-swap between unrelated row implementations
- height changes will go through the same batching and invalidation path as every other timeline item
- future features like translation, media re-layout, and row caching will stop needing anchor-specific exceptions

## Non-goals

- This plan does not require changing the server model.
- This plan does not require changing iOS immediately.
- This plan does not require a dedicated realtime update for the anchor.

## Recommendation

Do not patch this with another zero-duration AppKit reload in `reloadReplyThreadAnchorRow()`.

That would hide the initial symptom but keep the architecture wrong.

The correct fix is to make the anchor a first-class list item in the same view-model and table pipeline as the rest of the thread timeline.
