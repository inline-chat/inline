# macOS: Launch At Login Async Update + Loading UI (2026-02-07)

From notes (Feb 6, 2026): "change launch on login to run it in a background task and show loading in settings."

## Goals

1. Toggling "Launch at Login" does not block the UI.
2. The settings UI shows a clear loading/updating state while the OS registration call is in progress.
3. If the OS requires approval (`SMAppService.Status.requiresApproval`), the UI explains what to do.

## Current State

1. The toggle is bound directly to `AppSettings.shared.launchAtLogin`.
2. `LaunchAtLoginController` observes that value and calls `SMAppService.mainApp.register/unregister` synchronously.
3. Errors are logged and the toggle is reverted if the effective state differs.

Key files:
- Controller: `apple/InlineMac/Services/LaunchAtLogin/LaunchAtLoginController.swift`
- Settings UI: `apple/InlineMac/Views/Settings/Views/GeneralSettingsDetailView.swift`
- App startup: `apple/InlineMac/App/AppDelegate.swift`

## Spec

### 1. Add explicit UI state for the toggle

Expose state:
1. `launchAtLoginIsUpdating: Bool`
2. `launchAtLoginRequiresApproval: Bool`
3. `launchAtLoginLastError: String?` (optional)

This state should be driven by the controller, not inferred in the view.

### 2. Run ServiceManagement updates asynchronously

1. When the user toggles the setting, the controller starts a Task.
2. UI enters "updating" state immediately.
3. The controller updates the setting to the effective final value when the task completes.

### 3. Handle requires-approval status explicitly

If `SMAppService.Status.requiresApproval`:
1. Treat the setting as enabled (or “pending”) depending on OS semantics.
2. Show a short instruction in the settings UI (e.g. "Requires approval in System Settings").

### 4. Prevent “toggle bounce”

Avoid the toggle rapidly switching back and forth:
1. Disable the toggle while updating.
2. If an error occurs, show a short inline error and revert once.

## Implementation Plan

1. Add a small observable view model owned by `LaunchAtLoginController` or `AppSettings`.
2. Update `GeneralSettingsDetailView` to render:
3. Toggle (disabled while updating).
4. A `ProgressView` while updating.
5. An approval hint if needed.

## Testing Checklist

1. Toggle on: UI shows spinner, ends in correct state.
2. Toggle off: same.
3. Force approval-required state: UI shows instruction.
4. Simulate error: UI shows error and ends in effective state without repeated bouncing.

## Acceptance Criteria

1. No noticeable UI hitch when toggling.
2. Users understand when OS approval is required.

