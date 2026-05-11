# macOS slowdown disable experiments

Purpose: temporarily disable recent UI features one at a time so we can rerun Xcode/Instruments and identify what is causing the new-window/chat-open slowdown.

## Experiment 1: Native Tab Title/Icon Updates

Status: restored

Changed file:
- `apple/InlineMac/Features/NewUI/MainWindowSwiftUI.swift`

Disabled:
- `@State private var nativeTab = NativeWindowTabModel()`
- `.nativeWindowTab(title: nativeTab.title, icon: nativeTab.iconPeer)`
- `nativeTab.update(peer:)` on appear
- `nativeTab.update(peer:)` on route change
- `nativeTab.update(peer: nil)` on disappear

Kept enabled:
- Native tab keyboard shortcut registration (`Cmd+1...9`)
- Window registration and routing
- SceneStorage route restore

Hypothesis:
- The tab icon/title path may be adding route-change work through `ObjectCache` publishers and the AppKit `NSViewRepresentable` bridge. If disabling it improves route/open latency, restore this feature later with deferred updates after first frame or a cheaper non-observed snapshot path.

Result:
- Not the cause. Disabled path did not fix the slowdown, so the feature was restored.

Restore:
- Already restored.

## Experiment 2: AppKit Shell Hosting New SwiftUI Root

Status: removed

Tested changes:
- Added a temporary `InlineMacUseAppKitSwiftUIWindow` user default.
- Added `AppKitSwiftUIMainWindowController`, an AppKit-owned `NSWindowController` that hosted `MainWindowSwiftUI` in an `NSHostingController`.
- Routed AppDelegate window creation through the AppKit-hosted SwiftUI root when the experiment flag was enabled.
- Suppressed SwiftUI `WindowGroup` launch/restoration while testing the AppKit-hosted window.
- Added a temporary `MainWindowSwiftUI` routing bypass so AppKit hosting did not call SwiftUI `openWindow` / `dismissWindow`.

Result:
- AppKit-hosted SwiftUI root showed the same delayed persisted-nav behavior.
- The experiment has been removed from code so the app uses the normal SwiftUI shell path again.

Removed code:
- `apple/InlineMac/Features/NewUI/AppKitSwiftUIMainWindowController.swift`
- `InlineMacUseAppKitSwiftUIWindow`
- AppKit-hosted main-window controller registry in `AppDelegate`
- AppKit experiment launch/restoration overrides in `InlineApp`
- AppKit experiment routing bypass in `MainWindowSwiftUI`
