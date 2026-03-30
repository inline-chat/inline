# macOS: Back/Forward Navigation (Nav2) UX + Wiring (2026-02-07)

From notes (Feb 3-6, 2026): "add back/forward", "add an on hover trigger for forward ??!".

## Goals

1. Back/forward buttons accurately reflect navigation state (enabled/disabled) in real time.
2. Keyboard shortcuts work consistently (Cmd+[ and Cmd+], or equivalent).
3. UX is predictable across tabs/spaces (Nav2 history model).

## Current State

1. Nav2 maintains `history` and `forwardHistory` and exposes `canGoBack` / `canGoForward`.
2. Toolbar has back/forward buttons and calls `dependencies.nav2?.goBack()` / `goForward()`.
3. Toolbar button enabled state is only set once and does not observe Nav2 changes.

Key files:
- Nav2: `apple/InlineMac/App/Nav2.swift`
- Toolbar buttons: `apple/InlineMac/Features/Toolbar/MainToolbar.swift`

## Spec

### 1. Live enabled/disabled state

1. Toolbar should subscribe to Nav2 changes and call `updateNavigationButtonStates()` whenever:
2. `history` changes
3. `forwardHistory` changes
4. active tab changes

Implementation approaches:
1. If Nav2 is `@Observable`, add a small Combine publisher bridge or a callback hook.
2. Or expose a `PassthroughSubject<Void, Never>` on Nav2 that fires on state mutation.

### 2. Keyboard shortcuts

1. Ensure menu items or key handlers trigger Nav2 back/forward.
2. Avoid old navigation model (`dependencies.nav`) when new UI is enabled.

### 3. Hover-forward affordance (optional)

If desired:
1. On hover over back button, show a small popover with history stack.
2. On hover over forward, show forward stack.

This can be deferred; first ship correct enablement and click behavior.

## Implementation Plan

### Phase 1: Wiring (must-have)

1. Add observation from toolbar to Nav2 and update button states.
2. Ensure buttons are disabled when unavailable (and visually dimmed).

### Phase 2: Shortcuts parity

1. Ensure back/forward shortcuts route to Nav2 under new UI.
2. Ensure they do not conflict with text input shortcuts.

### Phase 3: History UI (nice-to-have)

1. Add a small history popover listing recent routes for quick jump.

## Testing Checklist

1. Navigate into a thread, open chat info, open profile, etc.
2. Back should be enabled and return to prior route.
3. Forward should re-apply the route.
4. Switching tabs maintains per-tab last route and does not corrupt history.

## Acceptance Criteria

1. Back/forward buttons enable/disable correctly without requiring app restart.
2. Back/forward shortcuts behave consistently.

