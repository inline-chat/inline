# UIKit Automatic Observation Tracking

## When To Read

Read this when using `@Observable` models from UIKit views, view controllers, cells, buttons, presentation controllers, or collection view layouts.

## Source Snapshot

- Automatic observation tracking: https://developer.apple.com/documentation/uikit/automatic-observation-tracking
- Updating views automatically with observation tracking: https://developer.apple.com/documentation/uikit/updating-views-automatically-with-observation-tracking
- `UIObservationTrackingEnabled`: https://developer.apple.com/documentation/bundleresources/information-property-list/uiobservationtrackingenabled
- `UIView.updateProperties()`: https://developer.apple.com/documentation/uikit/uiview/updateproperties()
- `UIViewController.updateProperties()`: https://developer.apple.com/documentation/uikit/uiviewcontroller/updateproperties()
- `UIView.setNeedsUpdateProperties()`: https://developer.apple.com/documentation/uikit/uiview/setneedsupdateproperties()
- `UIView.AnimationOptions.flushUpdates`: https://developer.apple.com/documentation/uikit/uiview/animationoptions/flushupdates
- UIKit updates: https://developer.apple.com/documentation/updates/uikit

## Availability

- UIKit automatic observation tracking can be back-deployed to iOS 18, iPadOS 18, and Mac Catalyst 18 with the `UIObservationTrackingEnabled` Info.plist key set to true.
- In iOS 26 and later, the key is not required; UIKit tracks observable object changes automatically.
- `updateProperties()` and `setNeedsUpdateProperties()` are iOS 26+, iPadOS 26+, Mac Catalyst 26+, tvOS 26+, visionOS 26+.
- `UIView.AnimationOptions.flushUpdates` is iOS 26+, iPadOS 26+, Mac Catalyst 26+, tvOS 26+, visionOS 26+.

For an iOS 18 deployment target, do not put required behavior only in `updateProperties()`. Use supported hooks such as `viewWillLayoutSubviews()`, `layoutSubviews()`, `updateConstraints()`, `draw(_:)`, or configuration update handlers, and keep the iOS 26 path gated.

## Info.plist Opt-In For iOS 18

```xml
<key>UIObservationTrackingEnabled</key>
<true/>
```

## Supported Tracking Surfaces

UIKit tracks `@Observable` property reads in these update methods or closures:

- Views: `updateProperties()` on iOS 26+, `layoutSubviews()`, `updateConstraints()`, `draw(_:)`.
- View controllers: `updateProperties()` on iOS 26+, `viewWillLayoutSubviews()`, `viewDidLayoutSubviews()`, `updateViewConstraints()`, `updateContentUnavailableConfiguration(using:)`.
- Presentation controllers: `containerViewWillLayoutSubviews()`, `containerViewDidLayoutSubviews()`.
- Buttons: `updateConfiguration()`, `configurationUpdateHandler`.
- Collection/table cells and table header/footer views: `updateConfiguration(using:)`, `configurationUpdateHandler`.
- Collection view compositional layouts: section provider closures can participate in automatic observation tracking.

## Preferred Pattern

Use `updateProperties()` on iOS 26+ for content and styling that does not need a layout pass. Use layout methods only for geometry.

```swift
@Observable
final class StatusModel {
    var showStatus = false
    var statusText = ""
}

final class StatusView: UIView {
    var model: StatusModel!
    private let label = UILabel()

    override func updateProperties() {
        super.updateProperties()
        label.alpha = model.showStatus ? 1 : 0
        label.text = model.statusText
    }
}
```

When you need to manually request an iOS 26+ properties update, call `setNeedsUpdateProperties()`; do not call `updateProperties()` directly.

## Cell Configuration Pattern

Cell configuration handlers are a good fit for frequently changing visible list item models:

```swift
cell.configurationUpdateHandler = { cell, _ in
    var config = UIListContentConfiguration.cell()
    config.image = model.icon
    config.text = model.title
    config.secondaryText = model.subtitle
    cell.contentConfiguration = config
}
```

UIKit tracks the observable properties read by the handler and reruns it while the cell is visible.

## Update Pass

UIKit's update pass runs trait updates, property updates, layout, display, then presentation. Keep content/style updates in `updateProperties()` when available to avoid unnecessary layout passes.

Use `.flushUpdates` for iOS 26+ animations when pending trait/property/layout invalidations need to be flushed around animation scopes.

## Avoid

- Do not call `updateProperties()` directly.
- Do not rely on `updateProperties()` for iOS 18 code paths.
- Do not do expensive work or broad model mutation inside tracked update methods.
- Do not keep manual `setNeedsLayout()`/`setNeedsDisplay()` calls that only compensate for observable property changes after automatic tracking is correctly installed.

## Review Checklist

- iOS 18 targets have `UIObservationTrackingEnabled` when relying on automatic tracking.
- iOS 26-only methods are gated or have an older fallback.
- Content/style work is separated from layout work.
- Tracked closures read only the model properties that should invalidate that surface.
- Manual invalidation remains only for non-observed changes or explicit imperative updates.
