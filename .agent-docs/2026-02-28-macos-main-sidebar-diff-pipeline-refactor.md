# macOS MainSidebar Diff Pipeline Refactor Plan

## Goals
- Keep first render synchronous for immediate paint.
- Compute subsequent list changes asynchronously off the main thread.
- Apply visibility-aware animations (animate only when visible rows are affected).
- Preserve stable-ID diff behavior and row view reuse.
- Prefer in-place updates over remove+insert when item identity is unchanged.

## Scope
- `apple/InlineMac/Features/Sidebar/MainSidebarList.swift`
- `apple/InlineMac/Features/Sidebar/MainSidebarItemCollectionViewItem.swift`
- `apple/InlineMac/Features/Sidebar/MainSidebarItemCell.swift`

## Implementation Steps
1. Add a snapshot build queue with generation tokens to coalesce rapid updates.
2. Split snapshot processing into:
   - input capture on main thread
   - pure snapshot-data construction on background queue
   - snapshot apply on main thread
3. Track changed item IDs and currently visible IDs to decide whether to animate.
4. Use `reloadItems` for changed, identity-stable rows (AppKit diffable snapshot does not expose `reconfigureItems`).
5. Keep initial snapshot apply synchronous and non-animated.
6. Keep existing `NSCollectionViewDiffableDataSource` identity model (`Item.chat(ChatListItem.Identifier)`).

## Second Pass (2026-02-28)
1. Added `RowLayoutSize` enum to keep layout sizing explicit for multiple sidebar formats.
2. Moved route observation from per-cell tracking to list-level tracking.
3. Added targeted visible-cell selection updates based on old/new route peer changes.
4. Switched compositional layout row heights to fixed (`.absolute`) to reduce repeated fitting.
5. Updated cells to incremental configure path:
   - cache leading-content identity (action/avatar) and only rebuild when identity changes
   - update avatar peer in place when identity is stable
   - update title/message/badges only when values change
   - keep scroll event subscription stable across configure calls
6. Added SF Symbol image caching in `SidebarItemActionButton`.

## Validation
- Focused compile for changed macOS sidebar files.
- Manual behavior checks:
  - initial sidebar paint remains immediate
  - updates remain stable under bursts
  - offscreen-heavy updates do not animate
