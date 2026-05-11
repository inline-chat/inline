# SwiftUI App Shell Migration Plan

## Summary

Move the macOS app from an AppKit-owned shell to a SwiftUI `App` shell incrementally.

The first milestone is intentionally small:

- app entry becomes a SwiftUI `App`
- existing `AppDelegate` stays alive through `NSApplicationDelegateAdaptor`
- the main app launches a minimal placeholder window from `Features/NewUI`
- old legacy / experimental macOS UI paths remain in the repo but are no longer the startup path

This keeps the first build focused on shell ownership, not on feature parity.

## Current Shell Notes

- Current app entry is AppKit-owned in `apple/InlineMac/main.swift`.
- Current shell lifecycle is centered in `apple/InlineMac/App/AppDelegate.swift`.
- Current main windows are owned by `NSWindowController` implementations in:
  - `apple/InlineMac/Features/MainWindowCustom/MainWindowControllerCustom.swift`
  - `apple/InlineMac/Features/MainWindow/MainWindowController.swift`
- Current app menu is manually installed in `apple/InlineMac/App/AppMenu.swift`.
- Current special surfaces already use AppKit windows/panels:
  - `apple/InlineMac/Features/Sidebar/SpacePickerOverlayWindow.swift`
  - `apple/InlineMac/Features/Update/UpdateWindowController.swift`
  - `apple/InlineMac/Windows/SettingsWindowController.swift`

## Migration Decisions

- New macOS shell work goes under `apple/InlineMac/Features/NewUI`.
- Legacy UI and previous experimental UI are not being ported forward.
- Old files stay in the repo for now but become unused.
- We prefer latest macOS 15 APIs and do not optimize for lower macOS versions.
- We keep AppKit where it remains the best tool:
  - custom `NSPanel` / `NSWindow` overlays
  - non-standard floating surfaces
  - any shell behavior SwiftUI scenes do not model well yet
- `AppDependencies` will later be split into smaller environment containers instead of one monolith.

## 10 Steps

1. Create a SwiftUI app entry.
   Keep `AppDelegate` bridged with `NSApplicationDelegateAdaptor`, but make the launched shell a small SwiftUI window from `Features/NewUI`.

2. Add a new `Features/NewUI` root surface.
   Create a clean placeholder `NewUIRootView` and `NewUIMainWindowView` with no old UI reuse.

3. Move primary window ownership into SwiftUI scenes.
   Use SwiftUI scene configuration for title, default size, resizability, and toolbar style.

4. Freeze old startup paths.
   Stop routing startup through legacy / experimental window controllers.

5. Split `AppDependencies`.
   Introduce smaller environment containers for app shell, session/auth, navigation, data, and settings.

6. Add a NewUI navigation model.
   Create a fresh SwiftUI-first shell state for loading, onboarding, and main app states.

7. Move app menus into SwiftUI `Commands`.
   Replace the manual AppKit menu surface first, keeping AppKit-only actions behind services where needed.

8. Add SwiftUI-owned secondary windows.
   Reintroduce `Settings`, utility windows, and other simple windows as SwiftUI scenes.

9. Reintroduce special overlays with AppKit bridges.
   Keep custom `NSPanel` / `NSWindow` surfaces for overlays, pickers, and tooltips that need AppKit semantics.

10. Finish lifecycle migration.
   Move URL handling, notification routing, restore behavior, and shell services into the SwiftUI app architecture, keeping only the delegate bridges still required.

## Step 1 Scope

### Goal

Reach a buildable macOS app that launches into an empty SwiftUI shell.

### Acceptance Criteria

- macOS app entry is a SwiftUI `App`
- app launches a placeholder NewUI main window
- `AppDelegate` no longer creates the old main window at launch
- `AppDelegate` no longer installs the old custom menu at launch
- existing service setup remains alive:
  - notifications
  - launch at login
  - dock badge
  - Sparkle setup
  - URL event registration
  - appearance setting

### Explicit Non-Goals For Step 1

- no feature parity with the old shell
- no settings scene migration
- no commands/menu migration
- no overlay/panel migration
- no navigation migration
- no dependency splitting yet

## Fresh Session Hand-off

If resuming from a fresh session, start by checking:

- `apple/InlineMac/main.swift`
- `apple/InlineMac/App/AppDelegate.swift`
- `apple/InlineMac/Features/NewUI/`

Then verify whether Step 1 is complete before moving to Step 2.
