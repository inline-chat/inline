# MAC_MESSAGE_REACTIONS_APPKIT_REWRITE_PLAN

Date: 2025-12-14
Owner: @mo + agent
Scope: `apple/InlineMac/Views/Message/MessageView.swift` reactions rendering only

## Why

Current macOS message reactions are rendered via SwiftUI hosted inside AppKit (`NSHostingView<ReactionsView>`). This makes layout/positioning and animation less predictable and harder to control.

We will replace the reactions subtree with pure AppKit so it:

- Uses deterministic layout (frames / explicit constraints).
- Animates reliably (fade + subtle pop, and smooth reflow).
- Uses standard AppKit input handling for clicks and context menus, without interfering with message-level gestures (long press / double click / selection).

## Goals

- Reactions chips render in AppKit (no SwiftUI hosting in message view).
- Chips support **click to toggle** (add/delete reaction) using standard AppKit behavior.
- Layout matches existing `MessageSizeCalculator` outputs:
  - Container size: `props.layout.reactions?.size`
  - Chip positions: `props.layout.reactionItems[emoji]?.spacing.(top/left)`
- Animations:
  - Insert/remove: fade + subtle pop.
  - Reflow (position changes): smooth move.
- Context menu on a chip:
  - Shows list of users who reacted and when (date).
  - Should be accessible via right click / control-click.

## Non-goals (for this rewrite)

- Changing reaction layout algorithms (wrapping rules, spacing) beyond what’s needed to make AppKit match existing output.
- Rewriting the reaction picker overlay.
- Cross-platform (iOS/web) changes.
- Replacing message-level gestures; only ensure we don’t conflict with them.

## Current State (baseline)

- `MessageViewAppKit` (AppKit) sets up reactions in `setupReactions()` by creating:
  - `ReactionsViewModel` (SwiftUI `ObservableObject`)
  - `NSHostingView<ReactionsView>` as `reactionsView`
- `MessageSizeCalculator` computes reaction layout using `ReactionItem.size(group:)` (currently a SwiftUI type in `apple/InlineMac/Views/Reactions/ReactionsView.swift`).

## Key Constraints / Inputs

- `FullMessage.groupedReactions: [GroupedReaction]` is the data source.
- `MessageSizeCalculator.LayoutPlan` (size + spacing) is the layout source.
- `MessageViewAppKit` already owns:
  - `reactionViewWidthConstraint`, `reactionViewHeightConstraint`, `reactionViewTopConstraint`
  - `props.layout.reactionsViewTop` for positioning relative to `contentView.topAnchor`

## Design Decisions

### 1) Standard AppKit click handling

Prefer `NSButton` (or `NSControl`) per chip rather than gesture recognizers:

- Correct hover/click behavior and accessibility defaults.
- Avoids conflicting with `MessageViewAppKit`’s gesture recognizers.

If message-level recognizers still receive events from chip clicks, add a recognizer delegate on the message view that ignores events whose `hitTest` lands inside the reactions view.

### 2) Deterministic positioning

Use a flipped container (`isFlipped = true`) and set chip frames directly from layout plan top/left offsets.

This avoids Auto Layout churn for frequent reflows and gives predictable animation targets.

### 3) Animation approach

Layer-backed views:

- Insert/remove: animate `alphaValue` and a small `CATransform3D` scale (e.g. 0.96 → 1.0).
- Reflow: animate frame changes via `NSAnimationContext` (`chip.animator().setFrameOrigin(...)` or `setFrame(...)`).

Keep it subtle; exact timings can be tweaked later (e.g. 0.12–0.18s).

### 4) Context menu content

Context menu is built per chip on demand from the chip’s `GroupedReaction`:

- Section header item: `<emoji> Reactions` (disabled).
- One item per reactor (sorted newest first or oldest first; decide during implementation):
  - Title: `"You"` for current user, otherwise `displayName`.
  - Subtitle/representedObject: formatted timestamp (relative if recent, absolute otherwise).

Implementation options:

- Simplest: one `NSMenuItem` per user with title `"<name> — <time>"`.
- Nicer: custom view menu items (later), but start simple.

## Implementation Plan

### Status

- [x] Phase 1 — Decouple sizing from SwiftUI
- [x] Phase 2 — AppKit chip view
- [x] Phase 3 — AppKit reactions container
- [x] Phase 4 — Integrate into `MessageViewAppKit`
- [x] Phase 5 — Conflict-free input handling
- [ ] Phase 6 — Manual verification checklist

### Phase 0 — Define acceptance checks

- Visual: chips match current look closely (height, padding, count/avatars behavior).
- Interaction: chip click toggles reliably without triggering:
  - message long press overlay
  - message double-click quick reaction
  - text selection interactions
- Layout: chips wrap identically to current behavior across widths.
- Updates: adding/removing reactions updates chips and reflows without glitches.
- Context menu: shows correct list and times.

### Phase 1 — Decouple sizing from SwiftUI

1. Create a new AppKit/shared sizing helper (file location TBD, likely under `apple/InlineMac/Views/Reactions/`):
   - `ReactionChipMetrics.size(group: GroupedReaction) -> CGSize`
   - Mirrors existing logic in `ReactionItem.size(group:)`:
     - emoji width (NSFont)
     - count width (NSFont)
     - avatar widths (max 3, overlap)
     - paddings
2. Update `MessageSizeCalculator` to use `ReactionChipMetrics.size(group:)` instead of `ReactionItem.size(group:)`.
3. Ensure no SwiftUI types are needed for layout computation.

### Phase 2 — AppKit chip view

1. Implement `ReactionChipButton: NSButton` (or `NSControl`) with:
   - emoji label
   - either avatars (≤ 3) or count label (> 3)
   - layer-backed rounded pill background
   - colors depending on:
     - outgoing vs incoming (`fullMessage.message.out`)
     - whether current user reacted
     - effective appearance (dark/light)
   - `toolTip` listing names (like current SwiftUI hover behavior)
2. Hook up action to a closure:
   - `onToggle(emoji: String, currentlyReacted: Bool)`
   - Caller performs realtime send on main actor.

Notes:

- Reuse existing `UserAvatarView` to match avatars elsewhere.
- For “we reacted” state, compute using `group.reactions.contains(where: userId == currentUserId)`.

### Phase 3 — AppKit reactions container

1. Implement `MessageReactionsView: NSView` with:
   - `isFlipped = true`
   - `wantsLayer = true`
   - internal map: `[String: ReactionChipButton]`
2. Add an update API:
   - `update(fullMessage: FullMessage, groups: [GroupedReaction], layout: [String: LayoutPlan], containerSize: CGSize)`
3. Diff + apply changes:
   - Removed emojis: animate out (fade + scale down), then remove from superview.
   - Added emojis: create chip, set initial state (alpha 0 + slight scale), animate in.
   - Existing emojis: update content and animate to new frame if needed.
4. Add context menu:
   - Either set `chip.menu` or override `menu(for:)` on the chip.
   - Build menu on demand from the current `GroupedReaction` data.

### Phase 4 — Integrate into `MessageViewAppKit`

1. Replace:
   - `reactionsViewModel: ReactionsViewModel?`
   - `NSHostingView<ReactionsView>`
     with:
   - `messageReactionsView: MessageReactionsView?`
2. Update `setupReactions()` to create the AppKit view and attach constraints (keep existing container constraints pattern).
3. Update the update paths:
   - `updateReactionsSizes()` becomes “push latest layout + groups into view”.
   - `updateReactions(prev:next:props:)` calls `messageReactionsView.update(...)`.
4. Remove `import SwiftUI` from `MessageView.swift` if no longer needed.

### Phase 5 — Conflict-free input handling

If chip clicks trigger `MessageViewAppKit` gesture recognizers:

1. Make `MessageViewAppKit` conform to `NSGestureRecognizerDelegate`.
2. Set delegates for `longPressGesture` / `doubleClickGesture`.
3. In `gestureRecognizer(_:shouldReceive:)`, return `false` when the event hits inside the reactions view.
4. Add temporary logs to debug click / gesture issues if they happen — ask the user to confirm.

### Phase 6 — Manual verification checklist

Use a chat with:

- 1 reaction (incoming + outgoing)
- 2–3 reactions (avatars shown)
- 4+ reactors on one emoji (count shown)
- multiple different emojis that wrap to 2+ lines

Verify:

- correct pill sizing and layout
- click toggles
- smooth add/remove/reflow animations
- context menu shows correct user list + timestamps

## Deliverables

- New AppKit reactions implementation (chips + container).
- `MessageViewAppKit` uses AppKit reactions (no SwiftUI hosting).
- `MessageSizeCalculator` reaction sizing no longer depends on SwiftUI types.

## Possible minor issues to watch out for

- Animation timing and easing not being similar to nstableview height animation updates
- Animation on first load should not happen
- Layout should wrap and should not use NSStackView.
