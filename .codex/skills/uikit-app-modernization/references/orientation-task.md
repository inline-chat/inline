# Task: userInterfaceOrientation Modernization

## Overview

`userInterfaceOrientation` (on `UIApplication` and `UIViewController`) and `orientation` on `UIDevice` encode orientation as an enum. Layout code that branches on orientation does not adapt to modern iOS — under multitasking, Stage Manager, and resizable scenes, "portrait vs landscape" no longer maps cleanly to the available space.

**Detection patterns:**

- `UIApplication.shared.statusBarOrientation`
- `UIApplication.shared.windows` + orientation
- `UIDevice.current.orientation`
- `self.interfaceOrientation` (deprecated UIViewController)
- Any comparison against `UIInterfaceOrientation` cases (`.portrait`, `.landscapeLeft`, etc.)

---

## Scope: Layout-Related Uses Only

**Only migrate uses that drive layout.** A use is layout-related if it:
- Appears in a `UIView` or `UIViewController` subclass (or extension)
- Appears in layout related methods like `layoutSubviews`, `updateProperties`, etc.
- Drives frame calculations, constraint setup, or visibility of UI elements
- Controls layout direction (horizontal vs vertical stacking)

**Leave non-layout uses alone** (camera capture, motion sensors, analytics, video recording). Add no TODO, make no change.

### Orientation Locking (Non-Layout)

For apps locking orientation (e.g., games), the modern API is `prefersInterfaceOrientationLocked` (iOS 26+). Override in VC and call `setNeedsUpdateOfPrefersInterfaceOrientationLocked()` when preference changes.

Outside this task's auto-fix scope. When encountering `supportedInterfaceOrientations` or forced orientation APIs, add a TODO:

```swift
// TODO: Modernization - Consider adopting `prefersInterfaceOrientationLocked` (iOS 26+)
// as the modern replacement for orientation locking via `supportedInterfaceOrientations`.
```

---

## Step 1: Classify the Purpose

| Category | How to recognize | Replacement approach |
|----------|-----------------|---------------------|
| **Constrained space removal** | Hides/removes UI in landscape to reclaim space | Size class check |
| **Aspect ratio detection** | Checks wider-than-tall to choose layout variant | Superview bounds comparison |
| **Subview flow direction** | Chooses horizontal vs vertical stacking | Size class or superview bounds |

---

## Step 2: Apply the Correct Replacement

### Pattern 1: Constrained Space → Size Class

| Original intent | Replacement |
|----------------|-------------|
| Narrow horizontal space (landscape iPhone) | `traitCollection.horizontalSizeClass == .compact` |
| Narrow vertical space (landscape iPhone hiding toolbar) | `traitCollection.verticalSizeClass == .compact` |

Use `self.traitCollection` in view/VC subclasses — never `UITraitCollection.current` when an instance is available.

---

### Pattern 2: Aspect Ratio → Compare Window Bounds (only when clearly equivalent)

**Do NOT replace with `width > height` heuristics when:**
- Code distinguishes **landscape-left vs landscape-right** — window bounds cannot distinguish these
- Orientation drives **animation direction or rotation transforms** — these depend on actual orientation
- Replacement requires inventing heuristics (checking `window.transform`) — never do this

In these cases, add a TODO explaining why bounds cannot substitute.

**When replacement IS clearly equivalent (simple portrait-vs-landscape for layout):**

```swift
// After
if view.bounds.height > view.bounds.width {
    useVerticalLayout()
} else {
    useHorizontalLayout()
}
```

In view controller subclasses using `view` to check for the available size is correct. In view subclasses, using `superview` is appropriate.

---

### Pattern 3: Subview Flow Direction → Size Class or View Bounds

Choose based on context:
- Decision "compact vs regular" → use size class (Pattern 1)
- Decision purely geometric ("wider than tall") → use view bounds (Pattern 2)

```swift
// Geometric — is the available space taller than wide?
stackView.axis = view.bounds.height > view.bounds.width ? .vertical : .horizontal

// Trait-based — compact width means stack vertically
stackView.axis = traitCollection.horizontalSizeClass == .compact ? .vertical : .horizontal
```
