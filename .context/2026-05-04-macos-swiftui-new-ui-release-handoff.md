# macOS SwiftUI New UI Release Handoff

Date: 2026-05-04
Branch: `swiftui-shell`
Goal: finalize the new SwiftUI macOS app/window entry so it is viable for merge and beta release, while keeping the previous AppKit shell recoverable enough to revert or rewire if needed.

## Read This First

- Keep new UI work in `apple/InlineMac/Features/NewUI` when possible.
- Do not make broad shared primitive changes just to support the SwiftUI shell. The AppKit legacy and experimental paths should remain usable or easy to rewire.
- The worktree is mixed staged, unstaged, and untracked. Do not blindly commit, stage, restore, or clean.
- The pending singleton in `MainWindowOpenCoordinator` is intentional. It supports "Open in New Tab" and "Open in New Window" context menu actions.
- `AGENTS.md` should stay in the repo.
- Settings should remain as a `Window` scene in `InlineApp.swift`; avoid reintroducing a separate custom settings scene unless there is a concrete reason.
- `Nav3` owns selected group/space state for the SwiftUI shell.
- The file/class introductions below are hints and orientation, not rules or ownership boundaries. Feel free to refactor, move, rename, extract, merge, or delete new WIP pieces as needed when it makes the SwiftUI shell simpler, more native, and more release-ready.

## Release Goal

The target is a beta-release-ready SwiftUI macOS shell, not a literal port of the AppKit shell. Prefer SwiftUI-first state, routing, environments, commands, windows, toolbars, sheets, and view composition. Use AppKit only for narrow macOS behaviors SwiftUI does not expose cleanly.

Keep the previous AppKit path, including legacy and experimental UIs it hosted, usable or at least easy to recover. Avoid changing shared primitives in ways that make reverting the SwiftUI shell harder.

For each polishing batch, favor the best single place to own behavior over duplicated defensive callbacks. Avoid redundant database observations, duplicate view models, and scattered method calls that make state hard to reason about.

## Current Product State

- The app now starts through a SwiftUI `@main` app in `apple/InlineMac/App/InlineApp.swift`.
- `AppDelegate` is still bridged with `@NSApplicationDelegateAdaptor`, so existing services remain alive: notifications, auth/session setup, realtime setup, Sparkle, dock badge, URL handling, global focus hotkey, and legacy shell hooks.
- Launch is split by auth state:
  - logged in: main SwiftUI window is presented
  - logged out: onboarding window is presented
- Onboarding has its own SwiftUI `Window` scene with hidden toolbar background, transparent/movable AppKit chrome, and `.defaultLaunchBehavior(.presented)` when logged out.
- Main window uses `NavigationSplitView`, a new SwiftUI sidebar, a route-based detail area, SwiftUI commands, and a SwiftUI command bar overlay wrapping the existing quick search view.
- The chat route still hosts the production AppKit chat view through a SwiftUI route wrapper. This is intentional for release viability.

## Main Architecture

### App Shell

- `apple/InlineMac/App/InlineApp.swift`
  - SwiftUI app entry.
  - Defines the main `WindowGroup`, onboarding `Window`, and settings `Window`.
  - Installs `CommandBarCommands`.
  - Uses `.windowToolbarStyle(.unified(showsTitle: false))` and content min-size window resizability.

- `apple/InlineMac/App/MacAppShellMode.swift`
  - Gates the shell with `UserDefaults` key `InlineMacUseSwiftUIShell`.
  - Default is currently SwiftUI shell enabled.
  - `MacAppInitialScene.presented` picks `.main`, `.onboarding`, or `.none`.

- `apple/InlineMac/App/AppDelegate.swift`
  - Keeps legacy AppKit startup behind `!MacAppShellMode.usesSwiftUI`.
  - Enables native window tabbing for the SwiftUI shell.
  - Routes notification/URL chat opens through `MainWindowOpenCoordinator` when SwiftUI shell is active.
  - Exposes `performLogOut()` for SwiftUI commands and onboarding transitions.

- `apple/InlineMac/App/AppDependencies.swift`
  - Existing dependency bag is extended for per-window SwiftUI state:
    - `nav3`
    - `nav3ChatOpenPreloader`
    - `forwardMessages`
    - `keyMonitor`
  - Adds helper methods like `requestOpenChat(peer:)`, `openChatInfo(peer:)`, and `activeSpaceId`.

### Window Opening And Tabs

- `apple/InlineMac/App/MainWindowOpenCoordinator.swift`
  - Central coordinator for opening the main window, onboarding, new windows, and native tabs.
  - Holds one pending destination to deliver a route to the next created SwiftUI window/tab.
  - Registers each live SwiftUI window by UUID.
  - `openWindow(_:)` prefers routing an existing key/visible window before creating a new window.
  - `openTab(_:)` uses native AppKit window tabbing because SwiftUI scene APIs do not expose enough tab control.

- `apple/InlineMac/Features/NewUI/Modifiers/MainWindowRegistration.swift`
  - Small `NSViewRepresentable` bridge that discovers the backing `NSWindow` and registers it with the coordinator.
  - Uses `DispatchQueue.main.async` after `viewDidMoveToWindow`; keep this bridge narrow if polishing.

### New Navigation

- `apple/InlineMac/Features/NewUI/Nav3.swift`
  - New per-window `@Observable` router.
  - Owns:
    - history stack
    - history index
    - command bar visibility
    - selected group/space id
  - Routes include:
    - `.empty`
    - `.chat(peer:)`
    - `.chatInfo(peer:query:)`
    - `.profile(userId:)`
    - `.createSpace`
    - `.newChat(spaceId:)`
    - `.inviteToSpace(spaceId:)`
    - `.members(spaceId:)`
    - `.spaceSettings(spaceId:)`
    - `.spaceIntegrations(spaceId:)`
  - Encodes/decodes route state into `@SceneStorage("main.lastRoute")`.

- `apple/InlineMac/Features/NewUI/MainWindowSwiftUI.swift`
  - Owns per-window `Nav3`, `KeyMonitor`, chat open preload bridge, forward messages presenter, and native tab icon state.
  - Injects per-window dependencies back into the environment.
  - Handles top-level route transitions from `MainWindowViewModel`.
  - Opens onboarding and dismisses main when top-level route becomes onboarding.
  - Fetches initial `getMe`, spaces, and chats once after entering main.

### Main Window Content

- `apple/InlineMac/Features/NewUI/MainWindowSwiftUI.swift`
  - `MainWindowRoot` composes:
    - `NavigationSplitView`
    - `SidebarView`
    - `MainContentView`
    - `MainWindowToolbar`
    - `CommandBar`
    - toast overlay host
    - forward messages sheet

- `apple/InlineMac/Features/NewUI/MainContentView.swift`
  - Renders `RouteView(route: nav.currentRoute)`.
  - Applies macOS 26 `scrollEdgeEffectStyle(.soft, for: .all)` where available.

- `apple/InlineMac/Features/NewUI/Routes/RouteView.swift`
  - Maps `Nav3Route` to the route view wrappers.

## Sidebar

- `apple/InlineMac/Features/NewUI/SidebarView.swift`
  - SwiftUI sidebar surface.
  - Uses `List` with custom rows, zero row insets, hidden separators, and animated item identity changes.
  - Top bar:
    - shows a home button only while inside a selected group
    - group picker is a native `Menu`
    - section title is `Groups`
    - final menu item is `Create Group`
    - selected group context menu lives on the picker and has a `Manage <group>` section with Settings, Members, and Add Member.
  - Footer:
    - archive toggle
    - search
    - view options menu
    - notification settings
    - new menu for Create Group/Create Chat/Invite

- `apple/InlineMac/Features/NewUI/SidebarViewModel.swift`
  - Dedicated SwiftUI sidebar view model.
  - Uses GRDB `ValueObservation` with `scheduling: .immediate` for frame-zero sidebar data where possible.
  - Has separate source modes:
    - home chats
    - group chats plus group contacts
  - Observes spaces separately.
  - Produces `activeItems` and `archivedItems`.
  - Merges duplicate chat/contact items and sorts pinned items first, then by date.

- `apple/InlineMac/Features/NewUI/SidebarChatItem.swift`
  - Custom SwiftUI sidebar row.
  - Opens on mouse down with `DragGesture(minimumDistance: 0)`.
  - Pressed state is intended to match selected style.
  - Unread dot uses scale plus opacity transition.
  - Pin icon is smaller and tertiary.
  - Last message preview uses tertiary color.
  - Context menu includes:
    - Open in New Tab
    - Open in New Window
    - Pin/Unpin
    - Mark Read/Unread
    - Archive/Unarchive

## Routes

- `apple/InlineMac/Features/NewUI/Routes/Chat/ChatRouteView.swift`
  - Hosts `ChatViewAppKit` via `AppKitRouteViewController`.
  - Uses new SwiftUI toolbar items around the AppKit chat surface.
  - Uses `ChatToolbarState` for toolbar sheets/popovers.
  - Toolbar includes title, notifications, participants, nudge, translation, and info/menu.

- `apple/InlineMac/Features/NewUI/Routes/Chat/ChatRouteTitleBar.swift`
  - SwiftUI title bar/title field integration.
  - Uses `WindowDragGesture` on the title area.

- `apple/InlineMac/Features/NewUI/Routes/Chat/ChatToolbarMenuButton.swift`
  - Native SwiftUI `Menu` for chat info/actions.
  - Uses `info.circle` for the label.
  - Handles rename, move to/from group, keep in sidebar, load history, pin, and archive.
  - Still observes menu state through GRDB and currently uses `.receive(on: DispatchQueue.main)` after the observation. Review if this causes any frame-zero issue.

- `apple/InlineMac/Features/NewUI/Routes/SwiftUIRouteViews.swift`
  - Wraps existing SwiftUI/AppKit-backed flows:
    - create group
    - new chat
    - invite
    - members
    - group settings
    - integrations
  - `CreateSpaceRouteView` calls `CreateSpaceSwiftUI { spaceId in nav.selectSpace(spaceId); nav.replace(.empty) }`.
  - Some routes still inject `Nav.main` for legacy compatibility. Keep these shims local and remove only when the wrapped view no longer needs legacy navigation.

- `apple/InlineMac/Features/NewUI/Routes/EmptyRouteView.swift`
  - Empty route surface.
  - Shows `Image("InlineLogoSymbol")` under 44 pt with low opacity and blend mode.
  - Tap opens command bar. Drag should still move the window.
  - Hides toolbar background on the empty page.
  - Uses `.containerBackground(.ultraThinMaterial, for: .window)` plus a white/black overlay.
  - Current focus gating uses `@Environment(\.appearsActive)`. If manual testing still says active/inactive does not follow key-window focus, replace this with a narrow AppKit key-window observer inside this file.

## Command Bar And Menus

- `apple/InlineMac/Features/NewUI/CommandBarCommands.swift`
  - SwiftUI `Commands` replacing key app/sidebar command groups for the SwiftUI shell.
  - New Window and New Tab are disabled unless the user is logged in and the top-level route is `.main`.
  - Logged-in-only actions like Log Out/Clear Cache/Clear Media Cache are disabled outside main.
  - Adds command bar, sidebar toggle, previous/next chat, always-on-top, and bold.

- `apple/InlineMac/Features/NewUI/CommandBarOverlay.swift`
  - SwiftUI overlay wrapper around `QuickSearchOverlayView`.
  - Attaches a reusable `QuickSearchViewModel` to `Nav3`.
  - Uses per-window `KeyMonitor` when available, with local NSEvent monitor fallback.

- `apple/InlineMac/Features/MainWindow/QuickSearchPopover.swift`
  - Existing quick search is extended for SwiftUI shell support.
  - Adds `nav3` attachment.
  - Adds `Back to Home`.
  - Supports group search, command ranking, local/global search, and create-thread fallback inside a selected group.
  - Product copy still mixes `space` and `group` in places, especially command titles/keywords. Polish pass should align user-facing copy to `Group`.

## Onboarding

- `apple/InlineMac/App/OnboardingWindowScene.swift`
  - Separate onboarding window scene.
  - Shows onboarding while `MainWindowViewModel.topLevelRoute == .onboarding`.
  - Opens main window and dismisses onboarding when route becomes `.main`.

- `apple/InlineMac/App/OnboardingWindowChrome.swift`
  - AppKit probe for hidden title, transparent toolbar, clear background, full-size content view, and movable-by-background behavior.

- `apple/InlineMac/Views/Onboarding/Onboarding.swift`
  - Updated to support window-container background mode.

## Assets And Build Identity

- `apple/InlineMac/Assets.xcassets/InlineLogoSymbol.imageset`
  - New empty-page symbol asset.
  - Asset name follows Apple casing: `InlineLogoSymbol`.
  - Current image selection was manually verified after swapping light/dark variants and restoring blend/opacity.

- Dev build app name should be `Inline-Dev`.
  - Related scripts:
    - `scripts/macos/build-direct.sh`
    - `scripts/macos/build-local-app.sh`
    - `scripts/macos/sign-direct.sh`
    - `scripts/macos/README.md`

## AppKit Bridges To Review, But Not Remove Blindly

- `NSApplicationDelegateAdaptor` in `InlineApp.swift`: required to keep existing app services alive.
- `MainWindowOpenCoordinator`: uses AppKit for native tabs and key-window routing.
- `MainWindowRegistration`: tiny `NSViewRepresentable` to discover the SwiftUI scene's `NSWindow`.
- `OnboardingWindowChrome`: tiny AppKit chrome probe because SwiftUI window modifiers do not expose every needed macOS window flag.
- `ToolbarItemIntrospector`: AppKit probe for `NSToolbarItem.visibilityPriority` and related properties that SwiftUI does not expose.
- `NativeWindowTabIconView` in `MainWindowSwiftUI.swift`: AppKit bridge for native tab accessory icons.
- `AppKitRouteViewController`: route wrapper for legacy AppKit content, especially the production chat view.

These are acceptable escape hatches for now. Keep them narrow and file-local where possible.

## Known Polish Targets For New Sessions

1. Empty-page focus/background behavior:
   - Verify `appearsActive` hides the white/black overlay when the window is not key/focused.
   - If unreliable, implement an AppKit key-window focus observer in `EmptyRouteView.swift`.
   - Keep the background movable and keep logo tap separate from click/drag behavior.

2. Sidebar interaction polish:
   - Re-test mouse-down open, pressed style, selected style, no hover animation, unread transition, and pin/archive animations.
   - Keep List diff performant and avoid native white selection artifacts.

3. Group picker and group copy:
   - Ensure all user-facing "space" copy in new UI routes/commands that should say "group" is updated.
   - Confirm picker does not show Home, has `Groups`, has `Create Group`, and manage actions only live on the picker.

4. Create Group:
   - Confirm loading/failure/success state.
   - On success, selected group should switch to the new group and route should return to empty.
   - Avoid duplicate API/database work.

5. Toolbar parity:
   - Verify chat toolbar title, info/menu, notification, participants, nudge, translation, overlays, sheets, and rename/move flows.
   - Keep native SwiftUI buttons where possible. Only use AppKit when SwiftUI cannot express the behavior.

6. Command bar:
   - Re-test Cmd+K shadow subtlety, search focus, arrows/vim/return handling, Back to Home, and create-thread fallback.
   - Align copy to Group where appropriate.

7. Window/tab behavior:
   - Re-test New Window/New Tab disabled while onboarding.
   - Re-test Open in New Tab/Open in New Window from sidebar row context menu.
   - Re-test Cmd+1...9 native tab selection.

8. Data/performance:
   - Keep sidebar GRDB observations on `.immediate` where frame-zero rendering matters.
   - Look for redundant view models or duplicated database observations before adding new state.
   - Do not hide loading flashes with arbitrary dispatches.

9. Legacy recovery:
   - Keep `Nav`, `Nav2`, AppKit controllers, and old route wrappers recoverable.
   - Avoid shared model/helper changes that make reverting the SwiftUI shell harder.

## Verification Commands

Fast build check:

```sh
xcodebuild -project apple/Inline.xcodeproj -scheme "Inline (macOS)" -configuration DevBuild -destination 'platform=macOS' build
```

Direct signed local app build for manual testing:

```sh
cd scripts
bun run macos:build-local-app -- --channel beta --sign
```

Expected local app output:

```text
build/InlineMacDirectLocal/Build/Products/DevBuild/Inline-Dev.app
```

Last known verification in this session:

- `xcodebuild -project apple/Inline.xcodeproj -scheme "Inline (macOS)" -configuration DevBuild -destination 'platform=macOS' build`
- Result: succeeded.
- Caveat: the worktree may have changed after that build during manual/Xcode iteration. Rerun after each polishing batch.
- Existing warnings are mostly pre-existing Swift concurrency/deprecation warnings outside the immediate new UI polish scope.

## Current Git State Snapshot

Branch:

```text
swiftui-shell
```

Unstaged tracked diff snapshot from `git diff --stat`:

```text
41 files changed, 1645 insertions(+), 686 deletions(-)
```

Staged snapshot from `git diff --cached --stat`:

```text
27 files changed, 1590 insertions(+), 136 deletions(-)
```

Important staged items to verify before commit:

- Existing app icon sets are staged as deleted:
  - `apple/InlineMac/Assets.xcassets/AppIcon.appiconset`
  - `apple/InlineMac/Assets.xcassets/InlineDebugAppIcon.appiconset`
- `InlineLogoSymbol.imageset` is staged as added.
- Several NewUI files are staged as added and also have unstaged edits.

Untracked files currently relevant to this migration:

```text
apple/InlineMac/App/InlineApp.swift
apple/InlineMac/App/MacAppShellMode.swift
apple/InlineMac/App/MainWindowOpenCoordinator.swift
apple/InlineMac/App/OnboardingWindowChrome.swift
apple/InlineMac/App/OnboardingWindowScene.swift
apple/InlineMac/Features/NewUI/CommandBarCommands.swift
apple/InlineMac/Features/NewUI/CommandBarOverlay.swift
apple/InlineMac/Features/NewUI/ForwardMessagesPresentation.swift
apple/InlineMac/Features/NewUI/MainContentView.swift
apple/InlineMac/Features/NewUI/MainWindowSwiftUI.swift
apple/InlineMac/Features/NewUI/MainWindowToolbar.swift
apple/InlineMac/Features/NewUI/Modifiers/MainWindowRegistration.swift
apple/InlineMac/Features/NewUI/Modifiers/OnEscapeKey.swift
apple/InlineMac/Features/NewUI/Routes/AppKitRouteView.swift
apple/InlineMac/Features/NewUI/Routes/Chat/ChatRouteToolbarTitleModel.swift
apple/InlineMac/Features/NewUI/Routes/Chat/ChatRouteView.swift
apple/InlineMac/Features/NewUI/Routes/Chat/ChatToolbarMenuButton.swift
apple/InlineMac/Features/NewUI/Routes/Chat/ChatToolbarNotificationButton.swift
apple/InlineMac/Features/NewUI/Routes/Chat/ChatToolbarParticipantsCoordinator.swift
apple/InlineMac/Features/NewUI/Routes/Chat/ChatToolbarTranslationCoordinator.swift
apple/InlineMac/Features/NewUI/Routes/ChatInfoRouteView.swift
apple/InlineMac/Features/NewUI/Routes/EmptyRouteView.swift
apple/InlineMac/Features/NewUI/Routes/ProfileRouteView.swift
apple/InlineMac/Features/NewUI/Routes/RoutePlaceholderView.swift
apple/InlineMac/Features/NewUI/Routes/RouteToolbarTitle.swift
apple/InlineMac/Features/NewUI/Routes/RouteView.swift
apple/InlineMac/Features/NewUI/Routes/SwiftUIRouteViews.swift
apple/InlineMac/Features/NewUI/SidebarFooter.swift
apple/InlineMac/Features/NewUI/ToolbarItemIntrospector.swift
apple/InlineMac/Toolbar/ChatRenamePermission.swift
```

## Core Review Files

Review these first in a fresh session:

1. `apple/InlineMac/App/InlineApp.swift`
2. `apple/InlineMac/App/AppDelegate.swift`
3. `apple/InlineMac/App/AppDependencies.swift`
4. `apple/InlineMac/App/MainWindowOpenCoordinator.swift`
5. `apple/InlineMac/Features/NewUI/MainWindowSwiftUI.swift`
6. `apple/InlineMac/Features/NewUI/Nav3.swift`
7. `apple/InlineMac/Features/NewUI/SidebarView.swift`
8. `apple/InlineMac/Features/NewUI/SidebarViewModel.swift`
9. `apple/InlineMac/Features/NewUI/SidebarChatItem.swift`
10. `apple/InlineMac/Features/NewUI/Routes/EmptyRouteView.swift`
11. `apple/InlineMac/Features/NewUI/Routes/Chat/ChatRouteView.swift`
12. `apple/InlineMac/Features/MainWindow/QuickSearchPopover.swift`

## Prior Context

Earlier migration plan:

```text
.context/2026-04-16-swiftui-app-shell-migration-plan.md
```

That file explains the original staged migration intent. This handoff reflects the later, more complete WIP state after sidebar, routes, onboarding, commands, empty page, and toolbar polishing began.
