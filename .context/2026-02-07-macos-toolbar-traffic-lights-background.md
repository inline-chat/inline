# macOS: Toolbar Background + Traffic Lights Alignment (2026-02-07)

From notes (Feb 3, 2026): "fix toolbar background starting after traffic lights".

This is a focused spec for the macOS new UI so the toolbar background starts after the traffic lights region (no gradient under the buttons) while toolbar content is still padded correctly.

## Goals

1. Toolbar background leading edge starts after the right-most traffic light (plus a small visual gap).
2. Toolbar content never overlaps traffic lights.
3. Behavior is correct for:
4. Sidebar visible
5. Sidebar collapsed
6. Traffic lights hidden/visible (depending on window state/preset)

## Current State (What Exists)

1. Toolbar background is a gradient view pinned to the toolbar bounds.
2. Toolbar content is a stack view with a leading padding constraint.
3. MainSplitView tracks traffic lights visibility and sidebar collapsed state and adjusts toolbar leading padding.

Key files:
- Toolbar: `apple/InlineMac/Features/Toolbar/MainToolbar.swift`
- Layout + traffic lights observer: `apple/InlineMac/Features/MainWindow/MainSplitView.swift`
Traffic lights layout stack:
1. `apple/InlineMac/Features/MainWindow/MainWindowController.swift`
2. `apple/InlineMacUI/Sources/InlineMacWindow/TrafficLightInsetWindow.swift`
3. `apple/InlineMacUI/Sources/InlineMacWindow/TrafficLightInsetApplierView.swift`
4. `apple/InlineMac/Features/MainWindow/TrafficLightSpacing.swift`

## Likely Failure Mode

1. Toolbar content is padded away from traffic lights, but the background gradient still renders underneath them in some states (notably when sidebar is collapsed and traffic lights are visible).
2. The result is “background doesn’t start after traffic lights” even though content does.

## Plan

### Phase 1: Add a background leading inset API (minimal regression risk)

1. In `MainToolbarView`, introduce a separate leading constraint for the background view (independent of the content stack padding).
2. Add a method like `updateBackgroundLeadingInset(_ inset: CGFloat, animated: Bool, duration: TimeInterval)`.
3. Default inset is `0` (full-bleed background when traffic lights are not visible).

### Phase 2: Compute inset from actual traffic light frames (avoid hardcoded guesses)

1. When traffic lights are visible, compute the max X of the right-most traffic light button:
2. Use `window?.standardWindowButton(.zoomButton)` or `.closeButton` to find the frame.
3. Convert to toolbar coordinate space.
4. Set inset to `maxX + gap` (gap ~8-12).

2. When traffic lights are hidden (fullscreen), set inset to `0`.

### Phase 3: Wire updates from MainSplitView (already observes presence)

1. Reuse the existing traffic light presence observer in `MainSplitView`.
2. On presence changes and sidebar collapse/expand, recompute and apply background inset.
3. Also update on window layout changes if needed (resize, titlebar inset changes).

### Phase 4: Keep clipping and corner radius behavior unchanged

1. Keep `contentArea.layer?.masksToBounds = true` in `MainSplitView` to preserve rounded corners.
2. This is a background-only inset, not a parent/child view move.

## Testing Checklist

1. Sidebar visible: background inset matches traffic lights region.
2. Sidebar collapsed: background still starts after traffic lights (no gradient behind buttons).
2. Switch light/dark mode: background colors still correct.
3. Fullscreen and split view: traffic lights behavior doesn’t break toolbar.

## Acceptance Criteria

1. Toolbar background starts after traffic lights in any normal window state.
2. Toolbar content never overlaps traffic lights.
