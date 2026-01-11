# Chat Performance Quick Wins (2026-01-06)

## Summary
Focused changes to reduce per-cell work during translation state updates, remove hot-path prints, cache multiline detection, and avoid forcing synchronous layout where it isn't required.

## Changes Made
- Centralized translating state updates in the collection view coordinator.
  - Files: `apple/InlineIOS/Features/Chat/MessagesCollectionView.swift`, `apple/InlineIOS/Features/Message/UIMessageView.swift`
  - `UIMessageView` no longer subscribes per-cell; it exposes `updateTranslatingState(_:)` and sets an initial state from the current publisher value.
  - Coordinator now listens once and updates only visible cells for the current peer.
- Cached multiline detection with an `NSCache` keyed by message metadata + display text.
  - File: `apple/InlineIOS/Features/Message/UIMessageView.swift`
  - Reduces repeated unicode scanning on re-layout and reuse.
- Removed `print` calls from chat/message hot paths.
  - Files: `apple/InlineIOS/Features/Chat/MessagesCollectionView.swift`,
    `apple/InlineIOS/Features/Message/UIMessageView.swift`,
    `apple/InlineIOS/Features/Message/URLPreviewView.swift`
- Reduced forced layout calls where layout is not required immediately.
  - Files: `apple/InlineIOS/Features/Chat/MessagesCollectionView.swift`,
    `apple/InlineIOS/Features/Chat/ChatViewUIKit.swift`
  - Replaced `layoutIfNeeded()` with `setNeedsLayout()` in `updateContentInsets()` and `handleComposeViewHeightChange`.
- Reduced scroll-time work and repeated near-top loading.
  - File: `apple/InlineIOS/Features/Chat/MessagesCollectionView.swift`
  - Throttled date separator visibility updates during scroll.
  - Added near-top load guards (cooldown + in-flight flag) to avoid repeated `loadBatch` calls.
  - Avoided section flattening by using `viewModel.messages.count` for bottom-state checks.
- Gated chat list updates while off-screen to reduce SwiftUI churn.
  - Files: `apple/InlineIOS/Utils/ChatListVisibilityGate.swift`, `apple/InlineIOS/Lists/ChatListView.swift`
  - Disables list animations and translation work when the list is not visible.

## Rationale
- Per-cell translation subscriptions multiply work on every translating-state update. Centralizing the subscription and updating only visible cells avoids unnecessary main-thread work and allocations.
- Multiline detection scans unicode scalars and emoji; caching avoids recomputation for unchanged message content.
- Removing `print` prevents unnecessary I/O on the main thread during scrolling and tap handling.
- Avoiding immediate layout passes reduces layout thrash during rapid inset updates and compose height changes.

## Notes / Risks
- Translating state updates now only touch visible cells. Newly displayed cells still initialize their translating state from the shared publisher value in `UIMessageView`.
- Multiline cache key includes message edit time, status, counts, and display text to avoid stale results when content changes.
- Layout changes do not modify constraint logic; they only defer layout to the next run loop.

## Follow-ups (Optional)
- Validate scrolling performance with Instruments (Time Profiler + Core Animation) on a long chat.
- If needed, add a lightweight metric to count per-frame layout passes during rapid scrolling.
