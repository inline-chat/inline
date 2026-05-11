# macOS Shell Legacy Cleanup Plan

Date: 2026-05-11

## Goal

The native SwiftUI shell migration is merged. The next cleanup should remove old macOS
window/sidebar/router paths without making the work feel irreversible.

The goal is a cleaner app tree with one obvious current shell, one obvious current sidebar,
and a recoverable history point for the removed legacy code.

## Inputs

This second pass is based on:

- Build macOS Apps guidance: explicit scenes, stable sidebar/detail layout, clear command
  and toolbar ownership, narrow AppKit escape hatches, and files named after their primary
  type.
- Ghostty macOS structure: `App`, feature-owned controllers/views, reusable helpers, and
  window/controller code kept inside the feature that owns it.
- InlineMacUI package shape: reusable macOS primitives belong in package targets only when
  they are isolated from app state, auth, database, routing, and product models.

## Recovery Tags

Use annotated tags so cleanup is easy to reference, diff, or recover from.

1. Pre native SwiftUI shell tag:

   ```sh
   git tag -a macos-shell-before-native-swiftui-2026-05-11 8472afa7 \
     -m "macOS shell before native SwiftUI window migration"
   git push origin macos-shell-before-native-swiftui-2026-05-11
   ```

   Target: `8472afa7 apple: fix chat cache consistency`, the commit immediately before
   `54bb6813 macos: adopt native swiftui shell`.

2. Post legacy cleanup tag:

   ```sh
   git tag -a macos-shell-after-legacy-cleanup-2026-05-11 <cleanup_sha> \
     -m "macOS shell after legacy window and sidebar cleanup"
   git push origin macos-shell-after-legacy-cleanup-2026-05-11
   ```

   Target this after the cleanup branch is merged and verified.

## Proposed Folder Shape

Do not keep a `Legacy/` folder in the active app target. Recovery should come from git tags
and this map, not from dead source files living beside current code.

Avoid an `AppShell` bucket. It is too close to `App/` conceptually and becomes another
catch-all. The production shell should be split by feature/ownership instead.

```text
apple/InlineMac/
  App/
    main.swift
    AppDelegate.swift
    AppDependencies.swift
    AppMenu.swift

  Features/
    MainWindow/
      MainWindowController.swift
      MainWindowRootView.swift
      MainContentView.swift
      MainWindowState.swift
      MainWindowRestoration.swift
      MainWindowOpenCoordinator.swift
      MainWindowSceneStateStore.swift
      MainWindowRegistration.swift
      NativeWindowTab.swift
      WindowAccessor.swift
      WindowAppearance.swift

    Navigation/
      Nav3.swift
      RouteView.swift
      RoutePlaceholderView.swift

    Sidebar/
      SidebarView.swift
      SidebarViewModel.swift
      SidebarChatItem.swift
      SidebarThreadIcon.swift
      SidebarFooter.swift
      ChatListItem.swift

    CommandBar/
      CommandBarOverlay.swift
      QuickSearchViewModel.swift
      QuickSearchOverlayView.swift
      QuickSearchCommands.swift

    Toolbar/
      MainWindowToolbar.swift
      ToolbarItemIntrospector.swift
      RouteToolbarTitle.swift

    Chat/
      ChatRouteView.swift
      ChatRouteTitleBar.swift
      ChatOpenPreloader.swift
      Toolbar/
        ChatToolbarState.swift
        ChatToolbarMenuButton.swift
        ChatToolbarNotificationButton.swift
        ChatToolbarParticipantsCoordinator.swift
        ChatToolbarTranslationCoordinator.swift

    ChatInfo/
    Profile/
    Compose/
    Messages/
    Onboarding/
    Settings/
    Update/

  Services/
  Support/
```

`Features/NewUI` should be dissolved into these feature folders. The UI is no longer
experimental or new; its files should be named by the production feature they own.

Keep `InlineMacUI` for reusable, app-independent macOS primitives:

```text
apple/InlineMacUI/Sources/
  InlineMacWindow/
  InlineMacHotkeys/
  InlineMacTabStrip/
  InlineMacUI/
  MacTheme/
```

Move code into `InlineMacUI` only if it does not know about `AppDependencies`, `Auth`,
`AppDatabase`, `Nav`, `Nav2`, `Nav3`, `Peer`, chat models, or product workflows.

## Ownership Rules

- `App/`: process entrypoint, app delegate, menu wiring, app-wide dependency construction,
  launch/auth/logout lifecycle, and global application services. Keep UI structure out of
  this folder.
- `Features/MainWindow/`: primary window controller, root view, split layout host,
  restoration, open coordinator, per-window registration, native tab metadata, and narrow
  window accessors/modifiers.
- `Features/Navigation/`: route model and route switch. It should be small. Route-specific
  views should live in their feature folder.
- `Features/Sidebar/`: one current sidebar, one sidebar item model, one sidebar chat row
  implementation.
- `Features/CommandBar/`: command/search overlay and its ranking/view model.
- `Features/Toolbar/`: shared main-window toolbar chrome only. Chat-specific toolbar state
  and actions should live under `Features/Chat/Toolbar/`.
- Product features: chat, chat info, compose, messages, settings, onboarding, update UI.
  These should not be considered legacy just because the files still live under `Views/`.
- `Services/`: app services with side effects or platform integration.
- `Support/`: small helpers/extensions that are not a product feature.
- `InlineMacUI`: reusable macOS components that can compile outside the app.

## Cleanup Phases

### Phase 1: Extract live code from legacy-looking files

Move still-active shared types before deleting old files:

- `TopLevelRoute` and `MainWindowViewModel` from
  `Features/MainWindow/MainWindowController.swift` to `Features/MainWindow/MainWindowState.swift`.
- `ChatListItem` can stay at `Features/Sidebar/ChatListItem.swift`, but after deleting old
  sibling files this path must clearly belong to the current sidebar. If that folder is
  still noisy during the implementation pass, move it together with the current sidebar
  files as one atomic rename.
- Command bar code from `Features/MainWindow/QuickSearchPopover.swift` to
  `Features/CommandBar/`.
- Chat open preloader from `Features/MainWindow/ChatOpenPreloader.swift` to
  `Features/Chat/ChatOpenPreloader.swift`.
- Chat toolbar sheets used by the current route toolbar from `Features/Toolbar/` to
  `Features/Chat/Toolbar/`.
- Sidebar footer metrics only if still used by current UI; otherwise localize or delete.

No behavior changes in this phase.

### Phase 2: Delete old main window stacks

After Phase 1 builds, remove old inactive shell files:

- `Features/MainWindow/MainWindowController.swift` after state extraction.
- `Features/MainWindow/MainSplitView.swift`.
- `Features/MainWindow/MainSplitView+Routes.swift`.
- `Features/MainWindow/MainSplitView+ContentPlaceholder.swift`.
- `Features/MainWindow/MainWindowView.swift`.
- `Views/Main/MainSplitViewAppKit.swift`.
- `Views/Main/SidebarContent.swift`.

Keep current SwiftUI window/root files under `Features/MainWindow/`.

### Phase 3: Delete old sidebar stacks

After the active sidebar owns `ChatListItem` and builds, remove the duplicate sidebar eras:

- `Views/Sidebar/HomeSidebar.swift`.
- `Views/Sidebar/NewSidebar/`.
- `Views/Sidebar/MainSidebar/`.
- `Views/SideItem/`.
- Inactive `Features/Sidebar/MainSidebar*`, `ChatsViewModel`, space-picker overlay files,
  and `SampleView`.

Before deletion, run one reference audit per type. If a file contains a still-useful product
view, move that view into the owning feature instead of keeping the old folder.

### Phase 4: Dissolve `Features/NewUI`

Move current production files out of `Features/NewUI` into feature-owned folders:

```text
Features/NewUI/MainWindowSwiftUIWindowController.swift -> Features/MainWindow/MainWindowController.swift
Features/NewUI/MainWindowSwiftUI.swift -> Features/MainWindow/MainWindowRootView.swift
Features/NewUI/MainContentView.swift -> Features/MainWindow/MainContentView.swift
Features/NewUI/Nav3.swift -> Features/Navigation/Nav3.swift
Features/NewUI/Routes/RouteView.swift -> Features/Navigation/RouteView.swift
Features/NewUI/Routes/RoutePlaceholderView.swift -> Features/Navigation/RoutePlaceholderView.swift
Features/NewUI/SidebarView*.swift -> Features/Sidebar/
Features/NewUI/SidebarChatItem.swift -> Features/Sidebar/
Features/NewUI/CommandBarOverlay.swift -> Features/CommandBar/
Features/NewUI/MainWindowToolbar.swift -> Features/Toolbar/
Features/NewUI/Routes/Chat/* -> Features/Chat/
```

Rename public/current types only where it improves clarity:

- `MainWindowSwiftUIWindowController` can become `MainWindowController` after the old
  controller is gone.
- `MainWindowSwiftUI` can become `MainWindowRootView`.
- `SidebarChatItemView` can stay if it is the only sidebar chat row type.

Avoid broad renames that only churn history.

### Phase 5: Optional package extraction

Only after the app cleanup is stable, consider moving isolated primitives into `InlineMacUI`:

- Generic window modifiers or window accessors with no app routing.
- Generic hotkey/key-monitor helpers if they can live under `InlineMacHotkeys`.
- Generic window chrome helpers if they belong with `InlineMacWindow`.

Do not move product-specific sidebar rows, route toolbar state, command behavior, or chat
models into `InlineMacUI`.

## Commit Plan

Keep cleanup commits unsquashed and revertable:

1. `macos: extract active shell shared types`
2. `macos: move command bar and toolbar shell code`
3. `macos: remove legacy main window stack`
4. `macos: remove legacy sidebar stack`
5. `macos: move current ui into feature folders`
6. Optional: `macos: move isolated window helpers to mac ui package`

If a regression appears, revert the smallest cleanup commit first. The pre-shell tag remains
available for full reference.

## Verification

Run after each deletion/rename phase:

- Build the macOS app locally.
- Build affected Swift packages.
- Launch smoke:
  - cold launch
  - login/onboarding route
  - main window open
  - new window
  - new tab
  - window/tab restoration
  - sidebar chat selection
  - sidebar space selection
  - command bar
  - chat route
  - chat info route
  - settings window
  - logout/reset navigation

Before the post-cleanup tag, also check GitHub Swift Tests and CodeQL on main.

## Notes

- This cleanup should not release a beta by itself.
- This cleanup should not change product behavior intentionally.
- Any behavior found to depend on old code should be moved to the current owning feature,
  not preserved by keeping legacy folders active.

## Execution Record

Completed on 2026-05-11:

- Dissolved `Features/NewUI` into feature-owned folders.
- Kept `App/` focused on app delegate, dependencies, menus, lifecycle, and process-level
  setup.
- Moved active window controller/restoration/state into `Features/MainWindow/`.
- Moved active navigation files into `Features/Navigation/`.
- Moved active sidebar files into `Features/Sidebar/`.
- Moved command/search UI into `Features/CommandBar/`.
- Moved chat route and chat-specific toolbar/participant files into `Features/Chat/`.
- Removed inactive legacy main-window, custom tab strip, old toolbar, old sidebar, and
  duplicate sidebar item implementations.

Verification performed:

- `git diff --check`
- reference audit for removed legacy type/path names under `apple/InlineMac` and
  `docs/history`
- `xcodebuild -project apple/Inline.xcodeproj -scheme "Inline (macOS)" -configuration Debug -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO build`

Result:

- Xcode Debug build succeeded.
- Existing generated protobuf warnings remain in `InlineKit/Sources/InlineProtocol/core.pb.swift`.
- No beta release was built or published.
