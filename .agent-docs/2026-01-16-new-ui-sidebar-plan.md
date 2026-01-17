# New Mac UI Sidebar + Layout Plan (2026-01-16)

## Goals
- Remove the current tab bar area from the new UI (commented out, not deleted).
- Replace the current AppKit sidebar with a new SwiftUI sidebar (commented out, not deleted).
- Extend the content view to fill the space previously occupied by the tab bar.
- Build the new SwiftUI sidebar UI per the provided spec and hook it to Nav2.

## References
- New UI wiring: `apple/InlineMac/Features/MainWindow/MainSplitView.swift`
- Tab bar: `apple/InlineMac/Features/TabBar/MainTabBar.swift`
- Current sidebar: `apple/InlineMac/Features/Sidebar/MainSidebar.swift`
- Sidebar item reference (SwiftUI): `apple/InlineMac/Views/SideItem/SidebarItem.swift`

## Plan
1. Map the current split view layout
   - Inspect `MainSplitView` and related route wiring to see where `MainTabBar` and `MainSidebar` are inserted, and how sizing is constrained.
   - Identify the container that must expand when the tab bar is removed.

2. Comment out the tab bar area
   - Comment out the `MainTabBar` creation and insertion points in `MainSplitView` (keep code intact with clear comments).
   - Update constraints so the content container’s top aligns to the split view’s top, filling the former tab bar area.
   - Verify toolbar positioning still behaves as expected.

3. Replace the AppKit sidebar with a SwiftUI sidebar
   - Comment out `MainSidebar` usage in the split view.
   - Add a new SwiftUI sidebar view, hosted via `NSHostingController` (e.g., `NewMainSidebarView`).
   - Keep width fixed, using existing sidebar edge insets and paddings derived from `MainSidebar`.

4. Build SwiftUI sidebar UI (minimal, no section headers)
   - Header: current space info or home user info (24px avatar + 14px name “(you)”) plus a grid button to open the spaces `NSMenu`.
   - Actions: `Search` and `New thread` rows using `MainSidebarRowButton` with 24x24 symbol area, 8px gap, 14px title.
   - Divider line at 0.05 black/white based on theme.
   - Chat list: DMs + threads mixed using `MainSidebarChatItem` (height 30px, hover highlight radius 12, active style white for light / ~0.2 for dark).
   - Hover X archive button, blue 4x4 unread dot 2px before avatar.
   - Footer: small leading archive toggle to switch inbox/archive.
   - Create sidebar sizing/padding constants on the new SwiftUI sidebar view and reuse in subviews.

5. Wire data + navigation (Nav2)
   - Use Nav2 to open chats and to switch to archive mode.
   - Reuse existing data sources / view models as feasible; if something is missing, document the gap and ask before proceeding.

6. Pass-through cleanup
   - Remove/disable any code paths that assumed the tab bar for layout.
   - Ensure content view stretches to the top; test visually for layout regressions.

## Open Questions / Risks
- Confirm how to access the spaces `NSMenu` logic currently in the tab bar to reuse in SwiftUI.
- Confirm source for mixed DM/thread list and archive toggle logic.
- Confirm whether selection state should be derived purely from Nav2’s active route.

## Status (2026-01-16)
- Done: Mapped MainSplitView wiring and commented out the tab bar area; content now anchors to the top.
- Done: Commented out AppKit sidebar usage and wired in the new SwiftUI sidebar hosting controller.
- Done: SwiftUI sidebar UI + view model (new header/actions/list/footer + mixed DM/thread data wiring + archive toggle).
