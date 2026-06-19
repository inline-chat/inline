# Observation Core

## When To Read

Read this for custom `@Observable` model classes, manual observation outside SwiftUI, `ObservationIgnored`, `withObservationTracking`, or questions about Observation API availability.

## Source Snapshot

- Apple Observation documentation: https://developer.apple.com/documentation/Observation
- `Observable` protocol: https://developer.apple.com/documentation/Observation/Observable
- `Observable()` macro: https://developer.apple.com/documentation/observation/observable()
- `ObservationIgnored()` macro: https://developer.apple.com/documentation/observation/observationignored()
- `withObservationTracking(_:onChange:)`: https://developer.apple.com/documentation/observation/withobservationtracking(_:onchange:)
- `ObservationTracking`: https://developer.apple.com/documentation/observation/observationtracking
- `withContinuousObservation(options:apply:)`: https://developer.apple.com/documentation/observation/withcontinuousobservation(options:apply:)

## Availability

- `@Observable`, `Observable`, `@ObservationIgnored`, `withObservationTracking`, and `ObservationTracking`: iOS 17+, iPadOS 17+, Mac Catalyst 17+, macOS 14+, tvOS 17+, visionOS 1+, watchOS 10+.
- `withContinuousObservation(options:apply:)`: documented as iOS 27+ beta, iPadOS 27+ beta, Mac Catalyst 27+ beta, macOS 27+ beta, tvOS 27+ beta, visionOS 27+ beta, watchOS 27+ beta. Do not use for iOS 18/macOS 15 or iOS 26/macOS 26 code unless the user explicitly wants beta-only APIs.

## Core Rules

- Add observation with the `@Observable` macro. Conforming to the `Observable` protocol by itself is only a signal to other APIs; it does not synthesize tracking.
- Observable stored properties do not need `@Published`.
- Accessible properties participate in observation by default. Mark accessible state with `@ObservationIgnored` when it is cache, logging, derived temporary state, or should not invalidate observers.
- Computed properties can be observed through the observable properties they read.
- Observation is dependency-tracked by property reads. Reading fewer properties narrows invalidation.
- Observation does not replace actor isolation. UI-owned observable models should usually be `@MainActor`, and mutations that affect UI should arrive on the main actor.

## Manual Tracking

Use `withObservationTracking` for custom renderers, imperative controllers, or framework glue that is not already tracked by SwiftUI/UIKit/AppKit.

```swift
import Observation

@MainActor
@Observable
final class BadgeModel {
    var unreadCount = 0
    var isMuted = false

    @ObservationIgnored
    var lastLogLine: String?

    var label: String {
        isMuted ? "Muted" : "\(unreadCount)"
    }
}

@MainActor
final class BadgeRenderer {
    let model: BadgeModel

    init(model: BadgeModel) {
        self.model = model
    }

    func render() {
        withObservationTracking {
            draw(label: model.label)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleRender()
            }
        }
    }

    private func draw(label: String) {}
    private func scheduleRender() {}
}
```

`withObservationTracking` is one-shot: the `apply` closure reads properties and `onChange` fires when one of those reads changes. Re-run the tracked work during the next render/update pass to establish fresh dependencies.

## Avoid

- Do not add both `@Observable` and `ObservableObject` to new model types unless you are in an explicit incremental migration.
- Do not keep `@Published` on properties after migrating the type to `@Observable`.
- Do not mutate observed state inside a tracked render/layout/draw pass unless you have a clear loop-prevention strategy.
- Do not use `withContinuousObservation` in production iOS 18/macOS 15 or iOS 26/macOS 26 code.

## Review Checklist

- The type uses `@Observable`, not bare `Observable`.
- Non-observed accessible properties are marked `@ObservationIgnored`.
- UI-observed models have appropriate actor isolation.
- Manual `withObservationTracking` work re-registers after invalidation.
- Future or beta APIs have explicit availability gates and user approval.
