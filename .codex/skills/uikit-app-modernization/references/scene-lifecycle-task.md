# Task: Scene Lifecycle Migration

## Overview

UIKit apps must adopt scene-based lifecycle (`UISceneDelegate`) to function correctly on modern iOS. The system dispatches foreground/background transitions per-scene, not per-app — apps that only implement `UIApplicationDelegate` lifecycle methods miss these events in multi-window scenarios.

**As of iOS 27, scene lifecycle is required.** Apps built against the iOS 27 SDK that haven't adopted it crash at launch.

**What this task does:** Migrates from `UIApplicationDelegate`-only lifecycle to `UISceneDelegate`-based lifecycle in 3 sequential steps.

**Cross-reference:** Resolves `UIWindow(frame: UIScreen.main.bounds)` TODOs from [uiscreen-task.md](uiscreen-task.md). After migration, use `UIWindow(windowScene:)` instead.

**Reference:** [TN3187: Migrating to the UIKit scene-based life-cycle](https://developer.apple.com/technotes/tn3187)

---

## Detection

**Migration needed** (proceed with all steps):
- `UIApplicationSceneManifest` key missing from Info.plist, AND
- No `configurationForConnecting` implementation in AppDelegate, AND
- No class conforming to `UIWindowSceneDelegate` found

**Already migrated** (STOP):
- `UIApplicationSceneManifest` exists in Info.plist with `UISceneConfigurations`, OR
- A class conforming to `UIWindowSceneDelegate` exists

**Partial migration** (ask user):
- Scene manifest exists but `UISceneConfigurations` empty/missing
- `configurationForConnecting` exists but no `SceneDelegate` class
- `SceneDelegate` exists but lifecycle methods not moved from AppDelegate

| What to search | Pattern |
|----------------|---------|
| Scene manifest | `UIApplicationSceneManifest` in Info.plist |
| Dynamic config | `configurationForConnecting` in AppDelegate |
| Scene delegate | `UIWindowSceneDelegate` conformance |
| Lifecycle in AppDelegate | `applicationDidBecomeActive`, `applicationWillResignActive`, `applicationDidEnterBackground`, `applicationWillEnterForeground` |

---

## Scope & Automation Level

| Action | Level |
|--------|-------|
| Add `UIApplicationSceneManifest` to Info.plist | **Auto-fix** |
| Create `SceneDelegate` boilerplate | **Auto-fix** |
| Move `UIWindow` creation to scene delegate | **Auto-fix** |
| Move 4 lifecycle methods (all four together) | **Auto-fix** |
| Choose Info.plist vs dynamic configuration | **Ask** |
| Split `didFinishLaunchingWithOptions` (one-time vs per-scene) | **Ask** |
| Add `SceneDelegate.swift` to `.pbxproj` | **Auto-fix** |
| URL handling / user activity / notification migration | **TODO** |

**Out of scope:** Multiple window support (`UIApplicationSupportsMultipleScenes` set to `false`), external display support.

**Do not repurpose a scene-lifecycle diff to swap an unrelated `UIScreen.mainScreen` reference.** When the active task is the scene-lifecycle migration but the file also happens to contain a `UIScreen.mainScreen` use that is NOT part of `UIWindow(frame: UIScreen.main.bounds)` (which Step 2 legitimately resolves), leave that `UIScreen.mainScreen` reference for the UIScreen task. Do not, for example, substitute `self.view` (a view controller's view) for an unrelated screen reference, or swap `[UIScreen mainScreen].scale` to `traitCollection.displayScale` while doing scene-lifecycle work. If the scene-lifecycle migration genuinely cannot be applied to this file (no AppDelegate lifecycle methods, already migrated, etc.), report "skipped: [reason]" — do not produce a diff that swaps an unrelated UIScreen usage to look like progress was made.

---

## Step 1: Add Scene Manifest to Info.plist

This step must complete before Step 2. The scene manifest activates the scene lifecycle system; without it, the system ignores `SceneDelegate` entirely.

**Ask the user:** "Should scene configuration be **static** (Info.plist — recommended) or **dynamic** (code in AppDelegate)?"

### 1A: Static Configuration (Info.plist) — Default

Add `UIApplicationSceneManifest` to the app's Info.plist:

```xml
<key>UIApplicationSceneManifest</key>
<dict>
    <key>UIApplicationSupportsMultipleScenes</key>
    <false/>
    <key>UISceneConfigurations</key>
    <dict>
        <key>UIWindowSceneSessionRoleApplication</key>
        <array>
            <dict>
                <key>UISceneConfigurationName</key>
                <string>Default Configuration</string>
                <key>UISceneDelegateClassName</key>
                <string>$(PRODUCT_MODULE_NAME).SceneDelegate</string>
                <!-- Include UISceneStoryboardFile only for storyboard-based apps -->
                <key>UISceneStoryboardFile</key>
                <string>Main</string>
            </dict>
        </array>
    </dict>
</dict>
```

For programmatic root VC setup (no storyboard), omit the `UISceneStoryboardFile` key.

### 1B: Dynamic Configuration (Code in AppDelegate) — Alternative

Info.plist still needs a minimal manifest (without `UISceneConfigurations`):

```xml
<key>UIApplicationSceneManifest</key>
<dict>
    <key>UIApplicationSupportsMultipleScenes</key>
    <false/>
</dict>
```

```swift
// In AppDelegate.swift
func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    config.delegateClass = SceneDelegate.self
    return config
}
```

For multiple scene roles, check `connectingSceneSession.role` to return the appropriate configuration.

---

## Step 2: Create SceneDelegate

Requires Step 1 complete. The scene manifest must reference the delegate class.

### 2A: Storyboard-Based App

System handles window creation. SceneDelegate only needs the `window` property:

```swift
// TODO: Modernization - Add SceneDelegate.swift to the Xcode project's Compile Sources build phase.
import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
}
```

### 2B: Programmatic Root View Controller

Move window creation from AppDelegate to scene delegate:

```swift
// TODO: Modernization - Add SceneDelegate.swift to the Xcode project's Compile Sources build phase.
import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = ViewController() // Replace with actual root VC
        window?.makeKeyAndVisible()
    }
}
```

`UIWindow(windowScene:)` replaces `UIWindow(frame: UIScreen.main.bounds)` — no frame needed.

---

## Step 3: Relocate Lifecycle Methods

Requires Step 2 complete.

### 3A: 1:1 Method Mappings

| AppDelegate | SceneDelegate |
|-------------|---------------|
| `applicationDidBecomeActive(_:)` | `sceneDidBecomeActive(_:)` |
| `applicationWillResignActive(_:)` | `sceneWillResignActive(_:)` |
| `applicationDidEnterBackground(_:)` | `sceneDidEnterBackground(_:)` |
| `applicationWillEnterForeground(_:)` | `sceneWillEnterForeground(_:)` |

**Migrate the four methods as a set, not individually.** The four events form a coherent observation cluster — observing some per-app and others per-scene produces mismatched counts on every multi-window state change. If all four bodies copy-paste cleanly to the scene equivalents (no `UIApplication` parameter access, no app-state branching), move all four. If any single method does not, do not migrate any of them in this pass.

Copy the method body unchanged; replace the `UIApplication` parameter with `UIScene`. Remove the moved methods from AppDelegate — if both exist, only the SceneDelegate version is called.

If the body calls helpers defined on AppDelegate, move them to SceneDelegate or to a shared utility. Accessing via `UIApplication.shared.delegate` is least preferred.

### 3B: `didFinishLaunchingWithOptions` — Always Ask

This method typically mixes one-time app setup and per-scene UI setup. **Always ask the user** which lines move.

**Stays in AppDelegate:** Analytics, database setup, push notifications, SDK initialization, global config.

**Moves to SceneDelegate `scene(_:willConnectTo:options:)`:** UIWindow creation, root VC setup, `makeKeyAndVisible()`, UI appearance config, state restoration. Window creation uses `UIWindow(windowScene:)` as shown in Step 2.

### 3C: Remove `window` Property from AppDelegate

After migration, `window` belongs on `SceneDelegate`. Remove `var window: UIWindow?` from AppDelegate. Search for and replace references: `appDelegate.window`, `(UIApplication.shared.delegate as? AppDelegate)?.window` → scene-appropriate access (e.g., `view.window`).

---

## API Reference

| API | Minimum iOS |
|-----|-------------|
| `UISceneDelegate` / `UIWindowSceneDelegate` | iOS 13.0+ |
| `UIWindowScene` / `UIWindow(windowScene:)` | iOS 13.0+ |
| `UISceneConfiguration` | iOS 13.0+ |
| `UIApplicationSceneManifest` (Info.plist) | iOS 13.0+ |

| Info.plist Key | Type | Description |
|----------------|------|-------------|
| `UIApplicationSceneManifest` | Dictionary | Root key — activates scene lifecycle |
| `UIApplicationSupportsMultipleScenes` | Boolean | `false` for single-window apps |
| `UISceneConfigurations` | Dictionary | Static scene configurations |
| `UIWindowSceneSessionRoleApplication` | Array | Standard window scene configs |
| `UISceneConfigurationName` | String | Configuration identifier |
| `UISceneDelegateClassName` | String | Scene delegate class name |
| `UISceneStoryboardFile` | String | Main storyboard (omit for programmatic) |

- [TN3187: Migrating to the UIKit scene-based life-cycle](https://developer.apple.com/technotes/tn3187)
- [Scenes — UIKit App Structure](https://developer.apple.com/documentation/uikit/app_and_environment/scenes)
