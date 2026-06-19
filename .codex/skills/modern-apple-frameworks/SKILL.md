---
name: modern-apple-frameworks
description: Use when writing, reviewing, or modernizing Swift code that touches Observation, SwiftUI model data, UIKit/AppKit automatic observation tracking, SwiftUI interoperability with UIKit/AppKit, or Apple APIs gated by iOS/macOS versions. Read this before adopting @Observable, migrating ObservableObject code, using new UIKit/AppKit lifecycle tracking, adding SwiftUI to existing UIKit/AppKit apps, or checking whether an iOS 18/macOS 15 or iOS 26/macOS 26 API is safe for the current deployment target.
---

# Modern Apple Frameworks

## Overview

Use this skill to pick modern Apple framework APIs without crossing the project's deployment target. The root file is a router; load only the reference guide that matches the code being changed.

Apple docs change quickly. Treat these references as a June 19, 2026 snapshot and verify official Apple documentation before using APIs that are beta, newly announced, or near the app's minimum OS.

## Before Coding

1. Identify the platform and deployment target from project settings, package manifests, xcconfigs, or surrounding code. In Inline, assume iOS 18 and macOS 15 unless local project settings say otherwise.
2. Read `references/os-availability.md` when the task mentions "modern", "latest", iOS/macOS 26, iOS 18, macOS 15, beta SDKs, or a newly announced API.
3. Read the task-specific guide below before editing code.
4. Gate unavailable APIs with `#available` or keep the older path. Do not use iOS/macOS 27 beta APIs unless the user explicitly asks for beta-only work.
5. In the final handoff, call out any OS gate, Info.plist key, fallback path, or beta limitation you relied on.

## Reference Selection

- `references/observation-core.md`: Use for `@Observable`, `Observable`, `ObservationIgnored`, custom observable model classes, `withObservationTracking`, `ObservationTracking`, and manual tracking outside SwiftUI.
- `references/swiftui-model-data.md`: Use for SwiftUI state, model ownership, `@State` with `@Observable`, `@Environment(Model.self)`, `@Bindable`, and migration from `ObservableObject`/`@Published`.
- `references/uikit-observation.md`: Use for UIKit automatic observation tracking, `updateProperties`, `setNeedsUpdateProperties`, cell configuration handlers, view/controller update methods, and `UIObservationTrackingEnabled`.
- `references/appkit-observation.md`: Use for AppKit automatic observation tracking, `draw(_:)`, `updateLayer()`, `layout()`, `updateConstraints()`, view-controller layout hooks, and `NSObservationTrackingEnabled`.
- `references/swiftui-interop.md`: Use when mixing SwiftUI into UIKit/AppKit: hosting views/controllers, `NSHostingMenu`, `NSHostingSceneRepresentation`, `UIHostingSceneDelegate`, `UIGestureRecognizerRepresentable`, `NSGestureRecognizerRepresentable`, Canvas, and menu/scene adoption.
- `references/os-availability.md`: Use when choosing APIs by OS version or checking the iOS 18/macOS 15 and iOS 26/macOS 26 support boundary.

## Current Defaults

- Prefer Observation for new SwiftUI-facing reference model classes when the target supports iOS 17+/macOS 14+.
- For SwiftUI-owned observable models, prefer `@State private var model = Model()` over `@StateObject`.
- For injected observable models in SwiftUI, pass a plain property unless the child needs bindings; use `@Bindable` only for binding creation.
- For UIKit/AppKit automatic tracking on iOS 18/macOS 15, add the documented Info.plist opt-in key. On iOS 26/macOS 26 and later, the opt-in keys are not required.
- Keep tracked update/draw/layout methods pure and cheap. Do not do database reads, network work, or broad state mutation inside those methods.

## Adding New API Guides

Add one markdown file under `references/` per API family. Keep files one level deep and add the new file to `Reference Selection` above.

Recommended structure for each guide: when to read, source snapshot, availability, preferred patterns, avoid, examples, and review checklist.
