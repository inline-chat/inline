# AppKit Automatic Observation Tracking

## When To Read

Read this when using `@Observable` models from AppKit views, view controllers, custom drawing, layer updates, Auto Layout updates, or cell drawing code.

## Source Snapshot

- Updating views automatically with observation tracking: https://developer.apple.com/documentation/appkit/updating-views-automatically-with-observation-tracking
- `NSObservationTrackingEnabled`: https://developer.apple.com/documentation/bundleresources/information-property-list/nsobservationtrackingenabled
- `NSView.draw(_:)`: https://developer.apple.com/documentation/appkit/nsview/draw(_:)
- `NSView.updateLayer()`: https://developer.apple.com/documentation/appkit/nsview/updatelayer()
- AppKit updates: https://developer.apple.com/documentation/updates/appkit
- WWDC26 session 272, "Use SwiftUI with AppKit and UIKit": https://developer.apple.com/videos/play/wwdc2026/272/

## Availability

- AppKit automatic observation tracking can be back-deployed to macOS 15 with the `NSObservationTrackingEnabled` Info.plist key set to true.
- In macOS 26 and later, the key is not required; AppKit tracks observable object changes automatically.
- The underlying `@Observable` macro is available earlier, starting macOS 14, but automatic AppKit view tracking needs the macOS 15 opt-in or macOS 26 default behavior.

## Info.plist Opt-In For macOS 15

```xml
<key>NSObservationTrackingEnabled</key>
<true/>
```

## Supported Tracking Surfaces

AppKit tracks `@Observable` property reads in supported view and view-controller update methods, including:

- `NSView.draw(_:)`
- Draw methods called as part of `NSView` drawing, such as custom cell drawing from controls
- `NSView.updateLayer()`
- `NSView.layout()`
- `NSView.updateConstraints()`
- `NSViewController.viewWillLayout()` and related AppKit layout/update hooks documented from the observation tracking article

When a supported method reads observable properties, AppKit tracks those reads and schedules the relevant view update when any read property changes.

## Preferred Pattern

Read observable properties exactly where they drive drawing, layer state, constraints, or layout.

```swift
@Observable
final class ColorModel {
    var hue: Double = 0
    var saturation: Double = 1
    var brightness: Double = 1
}

final class ColorSliderView: NSView {
    var model: ColorModel!

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawTrack(
            hue: model.hue,
            saturation: model.saturation,
            brightness: model.brightness,
            in: dirtyRect
        )
    }
}
```

For view-controller property updates:

```swift
override func viewWillLayout() {
    super.viewWillLayout()
    statusLabel.alphaValue = model.showStatus ? 1 : 0
    statusLabel.stringValue = model.statusText
}
```

## Design Notes

- This removes manual `needsDisplay = true` or `setNeedsDisplay(_:)` calls when those calls only exist to keep views in sync with observable model properties.
- Keep draw/layout/update methods cheap. They can run often and now may be scheduled by model changes.
- Separate concerns: draw in `draw(_:)`, layer-only changes in `updateLayer()`, geometry in `layout()`, and constraints in `updateConstraints()`.
- Do not mutate the model from the tracked method unless the code prevents update loops.

## Review Checklist

- macOS 15 targets have `NSObservationTrackingEnabled` when relying on automatic tracking.
- Tracked methods read only the properties that should invalidate that drawing/layout surface.
- Old manual invalidation was removed only where automatic tracking fully covers the dependency.
- Drawing and layout remain lightweight and side-effect-light.
- macOS 26-only interop APIs are gated separately; automatic tracking alone does not make those APIs available.
