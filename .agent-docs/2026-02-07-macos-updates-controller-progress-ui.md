# macOS Updates: Controller, Progress UI, Download Frequency (Sparkle) (2026-02-07)

From notes (Feb 6-7, 2026): "improve updating/update progress/download frequency by creating our own controller", "fix update button to be a capsule", "ensure notarize failure is communicated in bash instead of silent failure".

## Goals

- Users can understand update state (checking, downloading, extracting, ready).
- In-app UI surfaces update readiness without relying solely on Sparkle's standard windows.
- Update checks/downloads happen at a sane cadence.
- Build/release scripts never fail silently on notarization.

## Current State (What Exists)

Sparkle integration:
- Standard Sparkle UI is used via `SPUStandardUserDriver` wrapped by `UpdateUserDriverProxy`.
Files: `apple/InlineMac/Features/Update/UpdateController.swift`, `apple/InlineMac/Features/Update/UpdateUserDriverProxy.swift`.

In-app update readiness:
- When Sparkle reaches "Ready to install", we expose a sidebar overlay Update button.
Files: `apple/InlineMac/Views/Sidebar/UpdateSidebarOverlayButton.swift`, `apple/InlineMac/Features/Update/UpdateInstallState.swift`.

Custom update UI exists but is not wired in:
- `UpdateDriver` implements `SPUUserDriver` with a view model.
Files: `apple/InlineMac/Features/Update/UpdateDriver.swift`, `apple/InlineMac/Features/Update/UpdateViewModel.swift`, `apple/InlineMac/Features/Update/UpdateWindowController.swift`.

Notarization script already captures errors explicitly:
- `scripts/macos/build-direct.sh`

## Proposed Direction (Recommended)

Keep Sparkle as the engine, but switch from the standard user driver UI to Inline's own driver UI:
- Use `UpdateDriver` + `UpdateWindowController` for checking/downloading/error.
- Keep `UpdateInstallState` for the sidebar "Update" button when ready.

This gives:
- progress UI we control,
- consistent visuals with Inline,
- and the ability to rate-limit checks ourselves if Sparkle defaults are noisy.

## Plan (Implementation)

### 1. Wire custom user driver

- In `UpdateController`, replace `SPUStandardUserDriver` with `UpdateDriver`.
- Instantiate `UpdateViewModel`, `UpdateWindowController(viewModel:)` (presenter), and `UpdateDriver(viewModel: presenter:)`.
- Pass `UpdateDriver` to `SPUUpdater(userDriver: ...)`.

### 2. Keep sidebar "Update" button integration

- When `UpdateDriver.showReady(toInstallAndRelaunch:)` is invoked, call `UpdateInstallState.setReady(install:)`.
- Clear state on install/dismiss/error as appropriate.

### 3. Download/check cadence

Option A (simple):
- Keep Sparkle automatic checks but ensure user-configurable modes are respected.
Note: `AutoUpdateMode` already maps to Sparkle flags.

Option B (more control, aligns with "own controller"):
- Disable Sparkle automatic checks.
- Implement our own scheduler: check once on launch (delayed), then daily (or per user setting), jittered to avoid hammering.

### 4. Update button capsule

- Ensure the sidebar update button uses a capsule style consistently.
- Likely file: `apple/InlineMac/Views/Sidebar/UpdateSidebarOverlayButton.swift`.
- If `InlineButton` already renders as capsule, verify padding and corner radius in its implementation.

### 5. Notarization errors

- Confirm `scripts/macos/build-direct.sh` prints store-credentials errors, submit output and exit code, and `notarytool log` on non-Accepted statuses.
- If we still see silent failures, add `set -euo pipefail` safety and explicit `trap` to print context (only if needed).

## Acceptance Criteria

1. User-initiated "Check for Updates" shows Inline UI for checking/downloading/errors.
2. When ready, sidebar shows Update button and it triggers install.
3. Auto-update mode settings behave correctly (off/check/download).
4. Notarization failures are always printed with actionable info.

## Test Plan

Manual:
- Simulate update available (point feed to a test appcast or lower the current version in a local build).
- Verify each state transition shows correct UI.
- Confirm sidebar update button appears only when ready.

## Risks / Tradeoffs

- Sparkle user driver APIs are callback-heavy; ensure we don't leak closures or double-reply.
- Switching UI paths is user-facing; gate behind a flag if uncertain.
