# AppKit shell + SwiftUI window migration

Purpose: migrate macOS new UI from a SwiftUI `App` / `WindowGroup` shell back to an AppKit app shell while keeping the main window content SwiftUI-hosted.

Changed files:
- `apple/InlineMac/App/main.swift`
- `apple/InlineMac/App/AppDelegate.swift`
- `apple/InlineMac/App/AppMenu.swift`
- `apple/InlineMac/App/MainWindowRestoration.swift`
- `apple/InlineMac/App/MainWindowSceneStateStore.swift`
- `apple/InlineMac/App/InlineApp.swift`
- `apple/InlineMac/App/MacAppShellMode.swift`
- `apple/InlineMac/App/OnboardingWindowScene.swift`
- `apple/InlineMac/App/OnboardingWindowChrome.swift`
- `apple/InlineMac/Features/NewUI/MainWindowSwiftUIWindowController.swift`
- `apple/InlineMac/Features/NewUI/MainWindowSwiftUI.swift`
- `apple/InlineMac/Features/NewUI/Nav3.swift`
- `apple/InlineMac/Features/NewUI/CommandBarOverlay.swift`

Key migration points:
- App entry is `main.swift` + `AppDelegate`.
- `InlineApp`, `MacAppShellMode`, and SwiftUI scene-only onboarding files were removed.
- `MainWindowSwiftUIWindowController` owns AppKit `NSWindow` lifecycle and hosts `MainWindowSwiftUI`.
- `AppDelegate` retains multiple main window controllers and wires `MainWindowOpenCoordinator` into AppKit window creation.
- `MainWindowRestoration` uses AppKit `NSWindowRestoration` to restore main windows.
- AppKit owns frame, position, ordering, and tab-group restoration.
- The AppKit restoration payload stores the window scene ID and last active `Nav3` route state.
- `MainWindowSceneStateStore` now only provides the default scene ID and fresh scene IDs.
- `Nav3` route persistence no longer uses `@SceneStorage` or `UserDefaults`.
- Main-window route restore no longer uses `@SceneStorage`.
- Main windows now copy Ghostty's native-tab restoration workaround: set `tabbingMode = .preferred`, then return to `.automatic` on the next runloop.
- New tab creation now follows Ghostty's ordering: create the window hidden, remove accidental auto-tab membership, insert into the parent tab group, then order it front asynchronously.
- `Nav3` route changes invalidate the window's restorable state so the payload keeps the latest active route.
- Settings opens through `SettingsWindowController` from SwiftUI command bar paths.

Verification:
- `xcodebuild -project apple/Inline.xcodeproj -scheme 'Inline (macOS)' -configuration Debug -destination 'platform=macOS' -quiet build` passed.
- No remaining SwiftUI app-shell or main-window `@SceneStorage` references under `apple/InlineMac/App` or `apple/InlineMac/Features/NewUI`.
- No remaining flat scene-list restore path (`restoreLaunchWindows`, `sceneIdsForLaunch`, scene register/unregister).
- `git diff --check` for the touched macOS/context files passed. The repo-wide whitespace check is still blocked by unrelated trailing whitespace in `landing/src/docs/content/roadmap.md`.

Undo notes:
- Reintroduce `InlineApp.swift` as `@main` only if returning to SwiftUI scene ownership.
- Reintroduce `@SceneStorage` in `MainWindowScene` only if returning route persistence to SwiftUI scene state.
- Remove `main.swift` if switching back to SwiftUI `App` entry, since both entry points cannot coexist.
