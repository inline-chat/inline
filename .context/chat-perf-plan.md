# Chat Performance Plan

This doc tracks planned and completed work for chat scroll performance (UIKit) and SwiftUI shell invalidation.

## High Impact: Scroll-Time CPU & Layout
- [x] Reduce repeated near-top loads (cooldown + in-flight guard).
- [x] Throttle date-separator visibility updates during scroll.
- [x] Avoid repeated section flattening when checking bottom state.
- [ ] Debounce near-top load to scroll end (`scrollViewDidEndDecelerating`).
- [ ] Only update date separators when the pinned footer changes or scroll velocity is above a threshold.

## Medium Impact: Snapshot/Set Work
- [ ] Avoid repeated set-diff in `updateItemsSafely()` during long near-top drags.
- [ ] Track last snapshot IDs to skip full `setInitialData` unless sections/IDs changed.

## High Impact: SwiftUI ChatView Invalidation
- [x] Isolate toolbar content into a small subview with limited dependencies.
- [ ] Cache `ChatSubtitle` state (avoid recomputing in `body`).
- [ ] Wrap expensive toolbar subtree with `.equatable()` or `EquatableView`.

## Medium Impact: SwiftUI Rendering & Layout
- [ ] Debounce `navBarHeight` updates to avoid repeated blur/gradient recompute.
- [ ] Cache `chatProfileColors` keyed by `colorScheme`.
- [ ] Isolate animated indicators to prevent invalidating the full toolbar.

## High Impact: Initial Chat Open Lag
- [x] Confirm main-thread work on chat open with Instruments (Time Profiler + SwiftUI template).
- [x] Throttle duplicate refetches on open (guard `refetchHistoryOnly` and `.task` overlap).
- [ ] Apply first remote reload without animations to reduce diffable snapshot cost.
- [ ] Move initial message fetch (`MessagesProgressiveViewModel` init) off main actor or gate it until after first frame.
- [ ] Defer translation analysis on initial load (batch later or off main) to avoid blocking UI.
- [ ] Avoid immediate `layoutIfNeeded()` in `ComposeView.didMoveToWindow()` unless required.
  - Evidence: trace shows main-thread SwiftUI/AttributeGraph + UIKit layout during chat open.
  - Evidence: app frames include `HomeChatItem.__derived_struct_equals`, `EmbeddedMessage.__derived_struct_equals`,
    `MessageCollectionViewCell.configure`, `UIMessageView.setupViews/setupConstraints`.

## High Impact: Chat List Updates While Chat Is Open
- [x] Gate `ChatListView` animations and translation work when the list is off-screen.
- [ ] Avoid deep equality comparisons on `HomeChatItem`/`User`/`EmbeddedMessage` when list rows are off-screen.
- [ ] Narrow `onChange(of: items)` translation work to only item IDs with updated `lastMessage` identifiers.
- [ ] Consider a lightweight `Equatable` projection for list rows (id + lastMessage id/date + unread state).
  - Long-term: build a `ChatListRowModel` and publish only shallow, stable fields to SwiftUI.
  - Long-term: compute row diffs off-main, publish minimal changes on main.
  - Evidence: trace shows heavy `__derived_struct_equals` and copy/destroy of `HomeChatItem`, `User`, `EmbeddedMessage`.

## Notes
- Keep updates minimal and test after each change.
- Document changes in `.agent-docs/chat-perf-quick-wins-2026-01-06.md`.
 - Trace file: `/Users/mo/Downloads/ios-chat-open.trace` (iPhone SE, iOS 26.2).
