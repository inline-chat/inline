# Sidebar Header (New UI) AppKit Refactor

Date: 2026-02-07

## Goal

- Replace the SwiftUI-hosted sidebar header with a pure AppKit implementation (same behaviors, better reliability).
- Ensure the header layout is robust for a future resizable sidebar (no hard width assumptions, good compression behavior).
- Add Cmd+1...7 switching between `Nav2` tabs/spaces.

## Notes / Iterations

- Initial AppKit port uncovered common issues (hit-testing and menu anchoring). The header is now implemented as a single layer-backed row view with an explicit `hitTest` override so the whole row is clickable (except the menu button).
- Menu is presented using `NSApp.currentEvent` via `NSMenu.popUpContextMenu` for native positioning.
- Hover/expanded appearance is handled in AppKit directly (layer background + dynamic text tint), and updates on appearance changes.

## Work Items

1. Delete unused `MainSidebarSearchView` (confirmed no references).
2. Implement `MainSidebarHeaderView` and its row UI in AppKit.
3. Add `KeyMonitor` support for Cmd+1...7.
4. Wire Cmd+1...7 handler in `MainSplitView` to activate `Nav2` tabs.

## Status

- Implemented. Pending user-run macOS build/run to confirm visuals and interactions end-to-end.
