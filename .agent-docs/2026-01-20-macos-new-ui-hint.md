New macOS UI quick hint (new UI path)

Goal:
- A minimal, AppKit-native window layout, custom toolbar and sidebar and a set of new components to support our next generation of user experience which is centered around a sidebar with chats (threads/DMs) that user can "close" (archive) kind of like an inbox of threads.

General Direction and Current State:
- No NSSplitView or NSToolbar.
- Per-space view for sidebar — no more all chats in one sidebar.
- Smaller chat items, with a close button for archive
- Space title and a space picker in the sidebar
- A small archive button at sidebar footer
- Sidebar will be kind of a NSSplitView but our own and would support resize/collapse. 
- Custom window traffic light positioning and custom window drag region instead of native movable window.
- Currently behind an experimental flag, but as soon as stable, we'll ship it as default.
- Still needs polish around UI, interactions, speed, reliability, UX, porting keyboard shortcuts, adding search support, etc.
- We'll need a CMD+K popover to switch between chats

Entry + gating
- apple/InlineMac/Views/Settings/AppSettings.swift: enableNewMacUI flag stored in UserDefaults.
- apple/InlineMac/Views/Settings/Views/ExperimentalSettingsDetailView.swift: toggle UI for enableNewMacUI.
- apple/InlineMac/App/AppDelegate.swift: chooses MainWindowController (new UI) vs LegacyMainWindowController.

Window + deps
- apple/InlineMac/App/AppDependencies.swift: per-window deps; injects Nav2 + keyMonitor into SwiftUI env.
- apple/InlineMac/App/Nav2.swift: new nav model (routes, tabs, history, openSpace, persist tabs).
- apple/InlineMac/Features/MainWindow/MainWindowController.swift: owns TrafficLightInsetWindow, Nav2, swaps top-level routes.
- apple/InlineMac/Features/MainWindow/MainWindowView.swift: container that swaps the active VC.
- apple/InlineMac/Features/MainWindow/MainWindowBg.swift: window background visual effect + top highlight.

Core layout (MainSplitView)
- apple/InlineMac/Features/MainWindow/MainSplitView.swift: layout root; sidebar + content container (toolbar + content).
  - Applies inner padding + corner radius + shadow to content container.
  - Creates MainSidebar + MainTabBar; observes Nav2 to swap content.
- apple/InlineMac/Features/MainWindow/MainSplitView+Routes.swift: maps Nav2 routes to VCs and toolbar items.

Toolbar
- apple/InlineMac/Features/Toolbar/MainToolbar.swift: SwiftUI toolbar overlay; uses Theme.toolbarHeight and a top->bottom gradient.
  - Items: back/forward, chat title, participants, translate; bridges ChatTitleToolbar.
- apple/InlineMac/Toolbar/ChatTitleToolbar.swift: AppKit toolbar item for chat title + avatar.
- apple/InlineMac/Views/ChatIcon/ChatIconView.swift: ChatIconSwiftUIBridge supports ignoresSafeArea for titlebar use.

Sidebar
- apple/InlineMac/Features/Sidebar/MainSidebar.swift: sidebar controller + list; search field removed; no archive count footer.
- apple/InlineMac/Features/Sidebar/MainSidebarHeader.swift: header with space actions menu (no space picker button).
- apple/InlineMac/Features/Sidebar/MainSidebarList.swift: diffable list, sections, selection, Nav2-backed models.
- apple/InlineMac/Features/Sidebar/MainSidebarItemCell.swift: row UI, hover/selection, context actions.
- apple/InlineMac/Features/Sidebar/MainSidebarItemCollectionViewItem.swift: hosts cell and sizing.
- apple/InlineMac/Features/Sidebar/MainSidebarSearchView.swift: standalone search UI (not wired into MainSidebar).

Tabs
- apple/InlineMac/Features/TabBar/MainTabBar.swift: tab bar for Nav2 tabs.
- apple/InlineMac/Features/TabBar/MainTabItem.swift: visual states + close button.
- apple/InlineMac/Features/TabBar/MainTabItem+Helpers.swift: hover + context menu helpers.
- apple/InlineMac/Features/TabBar/TabSurfaceButton.swift: small surface-style button used by tab bar.

Content
- apple/InlineMac/Features/MainWindow/HomeSpacesView.swift: SwiftUI home/space list for Nav2Route.spaces.
- apple/InlineMac/Views/MessageList/MessageListAppKit.swift: adjusts top inset using window toolbar height.

New macOS UI support package
- apple/InlineMacUI/Sources/MacTheme/Theme.swift: shared sizing/colors (toolbarHeight, insets, radii).
- apple/InlineMacUI/Sources/InlineMacWindow/TrafficLightInsetWindow.swift: custom window, traffic light inset + double-click zoom.
- apple/InlineMacUI/Sources/InlineMacWindow/TrafficLightInsetApplierView.swift: reapplies traffic light positioning on layout.

Legacy (for comparison)
- apple/InlineMac/Views/Main/MainSplitViewAppKit.swift: legacy split view used when enableNewMacUI is off.
