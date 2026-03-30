# Space Tabs UI Work Log (Implemented Then Reverted)

Date: 2026-02-18
Author: Codex
Scope: macOS new UI (`apple/InlineMac`) space tabs feature behind a toggle, including menu action + hotkey and right-pane tabs strip layout.

## Original request context
Reintroduce "space tabs" on macOS behind a toggle, with:
- Toggle in app menu under View
- Hotkey `Cmd+Shift+S`
- Tabs rendered as pills above content (not previous melting tab UI)

Follow-up layout clarification requested:
- Tabs must be above the right content area (outside the white content box)
- Desired structure:
  - Left column: sidebar
  - Right column top row: tabs
  - Right column body: content

## Files that were changed for UI work

### 1) `apple/InlineMac/Views/Settings/AppSettings.swift`
Added persisted setting:
- `@Published var spaceTabsEnabled: Bool`
- Backed by `UserDefaults` key: `spaceTabsEnabled`
- Default value on startup: `false`

Purpose:
- Single source of truth for enabling/disabling tabs UI.

### 2) `apple/InlineMac/App/AppMenu.swift`
Added View menu wiring:
- New menu item title: `Show Space Tabs`
- Action: `toggleSpaceTabs(_:)`
- Hotkey: `Cmd+Shift+S` (`keyEquivalent: "S"`, modifiers `[.command, .shift]`)
- Menu validation checkmark state in `validateMenuItem(_:)`

Purpose:
- User-controllable toggle from View menu with keyboard shortcut.

### 3) `apple/InlineMac/Features/MainWindow/SpaceTabsStripView.swift` (new file)
Created a new pill-style SwiftUI tabs strip (not using old melting tab UI):
- `SpaceTabsStripView` bound to `Nav2`
- Renders all tabs including Home as first pill
- Selected state based on `nav2.activeTabIndex`
- Click pill -> `nav2.setActiveTab(index:)`
- Close button for non-home tabs -> `nav2.removeTab(at:)`
- Horizontal scrolling tabs row with capsule styling

Purpose:
- New visual style and behavior for tabs strip.

### 4) `apple/InlineMac/Features/MainWindow/MainSplitView.swift`
Added/changed layout and behavior for tabs strip:
- Added `spaceTabsStripView` hosting view + height constraint
- Added `SpaceTabsMetrics.height = Theme.tabBarHeight`
- Added observer for `AppSettings.shared.$spaceTabsEnabled`
- Added `applySpaceTabsVisibility(_:animated:)` with animation
- Built tabs root view from `SpaceTabsStripView(nav2:)`
- Final right-pane layout (as requested):
  - `spaceTabsStripView` pinned to `contentContainer.top`
  - `contentArea.top = spaceTabsStripView.bottom`
  - Toolbar stays inside `contentArea`
  - Routed content pinned to `contentArea`
- Moved shadow from `contentContainer` to `contentArea` so white content surface remains visually isolated below tabs row.

Purpose:
- Integrate tabs strip in new UI and match requested visual hierarchy.

### 5) `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`
Net UI-impacting logic:
- No functional tabs-specific logic retained in final version.
- Only formatting-level change around `pinnedHeaderTopConstraint` constructor (multiline formatting) relative to baseline.

Purpose during implementation:
- Early attempt briefly adjusted insets, later removed once tabs were structurally moved above content in `MainSplitView`.

## What was intentionally NOT reused
- Old tab/melting UI under `apple/InlineMac/Features/TabBar/*` was not integrated.

## Behavior delivered before revert
- View menu toggle + `Cmd+Shift+S` switched right-pane tabs strip on/off.
- Tabs included Home first, rendered as pills.
- Tabs row sat above right content area per follow-up layout requirement.

## Revert request
User requested:
- Save a full markdown document in `.agent-docs`
- Revert all UI work performed

This file is that full document.

## Revert scope (UI work only)
Planned/targeted revert files:
- `apple/InlineMac/App/AppMenu.swift`
- `apple/InlineMac/Views/Settings/AppSettings.swift`
- `apple/InlineMac/Features/MainWindow/MainSplitView.swift`
- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`
- delete `apple/InlineMac/Features/MainWindow/SpaceTabsStripView.swift`

## Revert completion
Completed.
- Restored tracked UI files listed above to their pre-change state.
- Removed `apple/InlineMac/Features/MainWindow/SpaceTabsStripView.swift`.
- Left unrelated workspace changes untouched.

Out-of-scope and intentionally untouched:
- Any unrelated modified files in working tree (from user/other agents/build side effects).
