# OS Availability Matrix

## When To Read

Read this before using any modern Apple framework API when the task mentions iOS 18, macOS 15, iOS/macOS 26, "latest", "new", "modern", "WWDC", or beta SDKs.

## Source Snapshot

- SwiftUI updates: https://developer.apple.com/documentation/updates/swiftui
- UIKit updates: https://developer.apple.com/documentation/updates/uikit
- AppKit updates: https://developer.apple.com/documentation/updates/appkit
- Swift updates: https://developer.apple.com/documentation/updates/swift
- WWDC26 session 272: https://developer.apple.com/videos/play/wwdc2026/272/
- API-specific docs linked from the other reference files.

## Project Baseline

Inline's project guidance says minimum versions are iOS 18 and macOS 15. Use that as the baseline unless local project files prove a different target.

## Always Check

- The deployment target.
- The SDK/Xcode requirement when Apple's update note says "Build your project in Xcode N or later".
- Whether the API is OS gated, SDK gated, or beta-only.
- Whether an Info.plist opt-in key is required on the baseline OS.

## Safe For iOS 18 / macOS 15 Baseline

| API or pattern | Availability | Notes |
| --- | --- | --- |
| `@Observable`, `Observable`, `ObservationIgnored`, `withObservationTracking` | iOS 17+, macOS 14+ | Safe for Inline baseline. |
| SwiftUI model data with Observation | iOS 17+, macOS 14+, Xcode 15+ | Prefer `@State` for owned observable model classes. |
| `UIGestureRecognizerRepresentable` | iOS 18+, iPadOS 18+, Mac Catalyst 18+ | Safe for iOS baseline; not AppKit. |
| UIKit automatic observation tracking | iOS 18+ with `UIObservationTrackingEnabled` | Required opt-in on iOS 18; default in iOS 26+. |
| AppKit automatic observation tracking | macOS 15+ with `NSObservationTrackingEnabled` | Required opt-in on macOS 15; default in macOS 26+. |
| `NSHostingMenu` | macOS 14.4+ | Safe for macOS 15. Mind delegate limitation on macOS 14 only. |
| SwiftUI 2024 APIs such as `TextSelection`, `MeshGradient`, `TextRenderer`, `ScrollPosition`, `onScrollVisibilityChange`, `presentationSizing`, `tabViewStyle(.sidebarAdaptable)`, `WindowDragGesture`, and `@Entry` | Generally announced in June 2024 docs | Verify exact symbol availability before use, but these are the iOS 18/macOS 15 generation. |
| UIKit 2024 APIs such as automatic trait usage tracking, `UIUpdateLink`, zoom transitions, tab sidebar mode, and UIKit gesture recognizer interop with SwiftUI | Generally announced in June 2024 docs | Verify exact symbol availability and platform scope. |
| AppKit 2024 APIs such as SwiftUI menus in AppKit, SwiftUI-backed AppKit animations, window tiling, toolbar display customization, and view/window loading attributes | Generally announced in June 2024 docs | Verify exact symbol availability and whether the feature is macOS-only. |

## iOS 26 / macOS 26 APIs

| API or pattern | Availability | Notes |
| --- | --- | --- |
| UIKit/AppKit automatic observation tracking by default | iOS 26+, macOS 26+ | Info.plist keys no longer required on 26+. |
| `UIView.updateProperties()` / `UIViewController.updateProperties()` | iOS 26+, iPadOS 26+, Mac Catalyst 26+, tvOS 26+, visionOS 26+ | Gate for iOS 18; use older supported hooks as fallback. |
| `setNeedsUpdateProperties()` | iOS 26+ family | Schedule, do not call update method directly. |
| `UIView.AnimationOptions.flushUpdates` | iOS 26+ family | Use to flush pending traits/properties/layout around animation scopes. |
| `UIHostingSceneDelegate` | iOS 26+, iPadOS 26+, Mac Catalyst 26+, visionOS 26+; tvOS 27 beta | Gate for iOS 18. |
| `NSGestureRecognizerRepresentable` | macOS 26+ | Gate for macOS 15. |
| `NSHostingSceneRepresentation` | macOS 26+ | Gate for macOS 15. |
| Liquid Glass APIs in SwiftUI/UIKit/AppKit | iOS 26+, macOS 26+ generation | Gate with `#available`; follow separate Liquid Glass skills when doing visual adoption. |
| SwiftUI `@Animatable` macro, attributed `TextEditor`, `FindContext`, WebKit `WebView`/`WebPage`, scroll edge and background extension effects, tab/search roles, Slider tick marks, window resize anchor | June 2025 SwiftUI updates | Verify exact symbol availability; most are the iOS/macOS 26 generation. |
| UIKit `UIGlassEffect`, `UIGlassContainerEffect`, glass button configurations, `UIBackgroundExtensionView`, `UIScrollEdgeEffect`, bar button badges, iPad menu bar updates, HDR color picker/headroom traits | June 2025 UIKit updates | Verify exact symbol availability and platform. |
| AppKit `NSGlassEffectView`, `NSGlassEffectContainerView`, glass button bezel, extra-large control size, background extension view, prominent toolbar item tint | June 2025 AppKit updates | Verify exact symbol availability and macOS target. |

## Do Not Use For iOS 18/macOS 15 Or iOS 26/macOS 26 Without Explicit Approval

| API or pattern | Availability | Why |
| --- | --- | --- |
| `withContinuousObservation(options:apply:)` | iOS 27+ beta, macOS 27+ beta, and peer beta platforms | Future beta-only according to Apple docs. |
| SwiftUI APIs that require building with Xcode 27 or later for their documented behavior, such as type-agnostic `@ContentBuilder` behavior | Xcode 27+ behavior | Toolchain-gated; verify local Xcode and SDK. |
| UIKit app lifecycle hard requirement after iOS 26 | Apple notes apps built with latest SDK must use scene lifecycle starting iOS 27 | Treat as migration planning unless the task is explicitly about iOS 27 readiness. |

## Version-Gating Pattern

```swift
if #available(iOS 26, macOS 26, *) {
    content
        .glassEffect()
} else {
    content
}
```

For platform-specific APIs, prefer platform-specific gates:

```swift
#if os(macOS)
if #available(macOS 26, *) {
    swiftUIView.gesture(ForceClickGesture())
} else {
    LegacyGestureHost(content: swiftUIView)
}
#endif
```

## Handoff Checklist

- State the minimum OS you targeted.
- State any `#available` gates or Info.plist keys added.
- State whether an API is beta-only or toolchain-gated.
- State the fallback behavior for older supported OS versions.
