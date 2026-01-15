New Mac UI context (flagged by AppSettings.enableNewMacUI)

apple/InlineMac/Views/Settings/AppSettings.swift
- Stores experimental flag enableNewMacUI in UserDefaults and publishes changes.

apple/InlineMac/Views/Settings/Views/ExperimentalSettingsDetailView.swift
- Settings UI toggle for “Enable new Mac UI” (plus sync updates toggle) with note about restart.

apple/InlineMac/App/AppDelegate.swift
- Chooses MainWindowController (new UI) vs LegacyMainWindowController based on enableNewMacUI.

apple/InlineMac/App/AppDependencies.swift
- Holds per-window Nav2 and keyMonitor; injects dependencies into SwiftUI environments including nav2.

apple/InlineMac/App/Nav2.swift
- New navigation model: routes, tabs, history/forward stack, active tab, per-tab last route; persists tabs/active index to JSON; openSpace/activateTab APIs.

apple/InlineMac/Features/MainWindow/MainWindowController.swift
- New window controller: instantiates Nav2, injects into dependencies, uses MainWindowView and MainSplitView; handles top-level route switching and basic toolbar setup.

apple/InlineMac/Features/MainWindow/MainWindowView.swift
- Container view controller that swaps the active child view controller.

apple/InlineMac/Features/MainWindow/MainWindowBg.swift
- NSVisualEffectView background used by MainWindowView (tint overlay + top highlight).

apple/InlineMac/Features/MainWindow/MainSplitView.swift
- New layout: tabs area, sidebar area, content container with toolbar; observes Nav2 to swap content and manage escape key navigation; sets MainSidebar/MainTabBar.

apple/InlineMac/Features/MainWindow/MainSplitView+Routes.swift
- Maps Nav2Route to content view controllers and computes toolbar item sets (MainToolbarItems) per route.

apple/InlineMac/Features/MainWindow/HomeSpacesView.swift
- SwiftUI “Home” spaces list for Nav2Route.spaces; opens space or create space via nav2.

apple/InlineMac/Features/Toolbar/MainToolbar.swift
- New toolbar view: SwiftUI-driven items (back/forward, chat title, participants, translate) and transparent mode; bridges existing ChatTitleToolbar.

apple/InlineMac/Features/TabBar/MainTabBar.swift
- Tab bar controller for Nav2 tabs; collection view layout with dynamic scaling; spaces menu button; opens/activates/close tabs.

apple/InlineMac/Features/TabBar/MainTabItem.swift
- Tab collection view item visuals: selected “melting” background, hover states, close overlay, title fade masking, home tab special-case.

apple/InlineMac/Features/TabBar/MainTabItem+Helpers.swift
- Hover tracking view, context menu for close, and NonDraggable view subclasses used by tab bar.

apple/InlineMac/Features/TabBar/TabSurfaceButton.swift
- Lightweight surface-style button used in pinned tab bar actions (e.g., spaces grid button).

apple/InlineMac/Features/Sidebar/MainSidebar.swift
- Sidebar controller with header, search field, list, archive toggle/footer; switches inbox/archive modes and updates empty state.

apple/InlineMac/Features/Sidebar/MainSidebarHeader.swift
- Sidebar header showing active tab (home/space) with hover/click menu for space actions (members/invite/integrations).

apple/InlineMac/Features/Sidebar/MainSidebarList.swift
- Core sidebar list: diffable data source, sectioning (threads/dms/archive/search), per-tab view models, search mode, selection, and scroll separators; uses Nav2 to choose active source.

apple/InlineMac/Features/Sidebar/MainSidebarItemCollectionViewItem.swift
- Collection view item wrapper that hosts MainSidebarItemCell and adjusts height for headers.

apple/InlineMac/Features/Sidebar/MainSidebarItemCell.swift
- Row/header rendering: avatar/title/badges, hover/selection states, context menu actions (pin/archive/read), action button, and Nav2 route highlighting.

apple/InlineMac/Features/Sidebar/MainSidebarSearchView.swift
- Dedicated search UI (SwiftUI search bar + MainSidebarList in search mode) with keyboard navigation (arrows/vim/escape) and placeholder states; not wired into MainSidebar yet.

apple/InlineMac/Features/Sidebar/SampleView.swift
- Sample/template NSViewController used for quick copy/paste when adding new sidebar-related views.

apple/InlineMac/Views/Main/MainSplitViewAppKit.swift
- Legacy split view controller used when enableNewMacUI is off (included for context of gating).
