# macOS Window Controls: Global Hotkey, Always On Top, Show On All Spaces (2026-02-07)

From notes (Feb 6-7, 2026): "global hotkey to open app", "always on top/show on all spaces", "toggle show on all workspaces".

## Goals

- Global focus hotkey is reliable and predictable.
- "Always on Top" is discoverable, reflects current state, and can persist (optional).
- Add "Show on all Spaces" (aka workspaces) toggle with correct AppKit behavior.

## Current State (What Exists)

Global hotkey:
- Carbon global hotkey registered by `apple/InlineMac/App/GlobalFocusHotkeyController.swift`.
- It calls `AppDelegate.showAndFocusMainWindow()` in `apple/InlineMac/App/AppDelegate.swift`.
- Settings UI exists in `apple/InlineMac/Views/Settings/Views/HotkeysSettingsDetailView.swift`.

Always on top:
- Window menu item toggles `NSWindow.level` between `.floating` and `.normal`.
File: `apple/InlineMac/App/AppMenu.swift`.
- This is per-window and not persisted. Menu item state is only updated when clicked, not when focus changes.

Show on all Spaces:
- Not implemented for the main window (no `collectionBehavior` toggle found).

## Spec: Behavior

### Global hotkey

- When pressed: if Inline is not active, activate and show main window; if Inline is active but main window is closed/hidden, show and focus. Optional: if Inline is frontmost and main window is focused, pressing hotkey can hide/minimize (decision).

### Always on Top

- Applies to main window only (at least initially).
- Menu item should reflect actual state for the key window.
- Optional persistence: if enabled, restore on launch.

### Show on all Spaces

- Toggles `NSWindow.collectionBehavior` to include `.canJoinAllSpaces`.
- Consider full screen behavior: add `.fullScreenAuxiliary` only if we explicitly want the window to appear over full-screen apps.
- Menu item state should reflect current window behavior.
- Persist setting and apply on window creation.

## Implementation Plan

1. Add a small "WindowBehaviorSettings" store backed by `AppStorage` or `UserDefaults` with fields `alwaysOnTopEnabled: Bool` and `showOnAllSpacesEnabled: Bool`.
2. Apply settings when creating/showing the main window in `AppDelegate.setupMainWindow()` (set `window.level` and `window.collectionBehavior` based on stored settings).
3. Add a Window menu item for "Show on All Spaces" near Always on Top; implement toggles that update the key window, persist the setting, and update menu item state.
4. Keep menu item state in sync via `NSMenuItemValidation` (set `.state` based on `keyWindow` level/collectionBehavior).
5. Verify global hotkey edge cases: ensure unregister/re-register works when updating hotkey; avoid UAF in Carbon handler (controller already has careful deinit).

## Acceptance Criteria

1. Hotkey always brings Inline to the front and focuses the main window.
2. Always-on-top toggles correctly and is reflected in the menu state.
3. Show-on-all-spaces toggles correctly and persists across relaunch (if we choose persistence).

## Test Plan

Manual:
- Test on multiple Spaces and with another app in full-screen.
- Toggle show-on-all-spaces and confirm behavior across space switches.
- Toggle always-on-top and confirm it stays above other windows.
- Change hotkey and confirm old hotkey no longer triggers.

## Risks / Tradeoffs

- `.fullScreenAuxiliary` can be surprising; default to not setting it unless requested.
- Persisting window behaviors can confuse users if they forget; consider adding a small indicator in settings.
