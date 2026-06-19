# SwiftUI Interoperability With UIKit And AppKit

## When To Read

Read this when adding SwiftUI to an existing UIKit/AppKit app, hosting SwiftUI in UIKit/AppKit, bringing UIKit/AppKit gestures into SwiftUI, defining menus in SwiftUI for AppKit, or adding SwiftUI scenes from existing app lifecycles.

## Source Snapshot

- WWDC26 session 272, "Use SwiftUI with AppKit and UIKit": https://developer.apple.com/videos/play/wwdc2026/272/
- SwiftUI updates: https://developer.apple.com/documentation/updates/swiftui
- `NSHostingMenu`: https://developer.apple.com/documentation/swiftui/nshostingmenu
- `NSHostingSceneRepresentation`: https://developer.apple.com/documentation/swiftui/nshostingscenerepresentation
- `UIHostingSceneDelegate`: https://developer.apple.com/documentation/swiftui/uihostingscenedelegate
- `UIGestureRecognizerRepresentable`: https://developer.apple.com/documentation/swiftui/uigesturerecognizerrepresentable
- `NSGestureRecognizerRepresentable`: https://developer.apple.com/documentation/swiftui/nsgesturerecognizerrepresentable
- `ContentBuilder`: https://developer.apple.com/documentation/swiftui/contentbuilder

## Availability

- `NSHostingMenu`: macOS 14.4+.
- `UIGestureRecognizerRepresentable`: iOS 18+, iPadOS 18+, Mac Catalyst 18+.
- `NSGestureRecognizerRepresentable`: macOS 26+.
- `NSHostingSceneRepresentation`: macOS 26+.
- `UIHostingSceneDelegate`: iOS 26+, iPadOS 26+, Mac Catalyst 26+, visionOS 26+, tvOS 27+ beta.
- `ContentBuilder`: broadly available as a `ViewBuilder` typealias, but Xcode 27 or later adds the documented type-agnostic content behavior that replaces type-specific builders.

## Adoption Strategy

1. Move shared UI state to `@Observable` first. That lets UIKit/AppKit automatic tracking and SwiftUI body tracking share the same model.
2. Use SwiftUI for a new component or a component rewrite when drawing and interaction would change substantially anyway.
3. Host SwiftUI at the narrowest stable boundary: `NSHostingView`, `NSHostingController`, `UIHostingController`, or a scene/menu-specific hosting API.
4. Keep existing UIKit/AppKit lifecycle and architecture unless a full SwiftUI app lifecycle migration is part of the task.

## Drawing And Hosting

SwiftUI `Canvas` is a good migration target for immediate-mode drawing that used to live in `draw(_:)` or `drawRect` style APIs. It can issue strokes, fills, transforms, and filters, and can reuse Core Graphics drawing through `withCGContext`.

For AppKit hierarchies, wrap the SwiftUI view in `NSHostingView` when you need an `NSView` boundary. For UIKit, use `UIHostingController` or `UIHostingConfiguration` depending on the existing surface.

## Gesture Recognizer Representables

Use representables to reuse existing gesture recognizer subclasses in SwiftUI.

```swift
struct ResetGesture: UIGestureRecognizerRepresentable {
    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        UILongPressGestureRecognizer()
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: UILongPressGestureRecognizer,
        context: Context
    ) {
        guard recognizer.state == .began else { return }
        reset()
    }
}
```

Attach with `.gesture(ResetGesture())`. Use the context coordinate-space converter when the recognizer reports coordinates in a different view than the SwiftUI view.

On macOS, `NSGestureRecognizerRepresentable` is macOS 26+. Gate it, and keep an `NSViewRepresentable` or AppKit-side gesture fallback for macOS 15 targets.

## SwiftUI Menus In AppKit

Use `NSHostingMenu` to define AppKit menu content with SwiftUI:

- It is an `NSMenu` subclass.
- Its items are derived from `rootView`; do not mutate `items` directly.
- Use `Group`, `Section`, `Button`, `Menu`, `Picker`, and `keyboardShortcut` in the SwiftUI root.
- Do not use an `HStack` as the top-level menu root because it can collapse intended separate actions into one menu item.
- For `NSPopUpButton`, set `NSPopUpButtonCell.usesItemFromMenu` to false.
- On macOS 14, do not change the hosting menu delegate. macOS 15+ permits setting the delegate.

## SwiftUI Scenes From Existing Lifecycles

Use `NSHostingSceneRepresentation` on macOS 26+ to add SwiftUI scenes from an AppKit app delegate:

```swift
let settingsScene = NSHostingSceneRepresentation {
    Settings {
        SettingsView()
    }
}

func applicationWillFinishLaunching(_ notification: Notification) {
    NSApplication.shared.addSceneRepresentation(settingsScene)
}

@IBAction func showSettings(_ sender: NSMenuItem) {
    settingsScene.environment.openSettings()
}
```

Use `UIHostingSceneDelegate` on iOS 26+ to activate SwiftUI scenes from UIKit by delegate class and scene ID or value.

## Review Checklist

- Shared state is observable before bridging, or the bridge has a clear data sync boundary.
- The chosen hosting API is available on the deployment target.
- macOS 26/iOS 26 interop APIs are gated for older app targets.
- Menus use SwiftUI menu semantics and avoid direct mutation of hosted `NSMenu.items`.
- Gesture recognizer representables provide a fallback for unsupported OS versions or input devices.
