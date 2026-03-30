# macOS Release: TestFlight + Direct Distribution Checklist (2026-02-07)

From notes (Feb 1-7, 2026): "release macOS", "release a new testflight build for macOS after fixing bugs with old UI", "send macOS full version, and direct vs app-store variant", "ensure notarize failure is communicated in bash instead of silent failure".

This is a release readiness plan, not an implementation diff.

## Goals

1. Ship a macOS build with fewer papercuts (especially old UI bugs) and a reliable update UX.
2. Have a repeatable release checklist for both:
3. TestFlight / App Store channel.
4. Direct distribution (Sparkle) channel.
5. No silent failures in release scripts (notarization/signing errors must fail loudly).

## Current State (Known)

1. Direct distribution exists and uses Sparkle (see existing Sparkle plans in `.agent-docs/`).
2. There is a local release script for macOS beta channel:
3. `bash scripts/macos/release-local.sh --channel beta`

## Decide The Channel Strategy (Explicit)

Option A: App Store only
1. Simplest compliance story.
2. Updates mediated by App Store.
3. Slower iteration cadence and review cycles.

Option B: Direct distribution only
1. Fast iteration via Sparkle.
2. Must maintain signing, notarization, feed hosting, and delta updates.
3. More operational surface area.

Option C (Recommended): Dual channel
1. App Store for mainstream installs.
2. Direct distribution for power users and rapid iteration.
3. Requires clear UX and channel separation to avoid confusion.

## Pre-Release Bug Fix Gate (Old UI)

Before shipping a broader build, fix or explicitly accept these:
1. Sidebar initial load animation/lag.
2. Rename UX issues (dbl click/Return).
3. Archive mode repeated actions.
4. Toolbar background/fade issues.
5. Notifications title/clearing correctness.

Specs that cover most of these:
- `/.agent-docs/2026-02-07-macos-new-ui-polish-batch.md`
- `/.agent-docs/2026-02-07-archive-mode-ux-fixes.md`
- `/.agent-docs/2026-02-07-macos-rename-thread-title-ux.md`
- `/.agent-docs/2026-02-07-notifications-title-clearing-per-chat-settings.md`

## Release Checklist (Both Channels)

1. Confirm version number bump strategy (build number and semantic version).
2. Confirm update UI works:
3. Update button is discoverable and progress is visible.
4. Update frequency is sane (no noisy polling).
5. Run focused package builds/tests:
6. `cd apple/InlineKit && swift test`
7. `cd apple/InlineUI && swift build`
8. `cd apple/InlineMacUI && swift test`

9. Manual smoke test:
10. Login, open a space, open a thread, send a message, receive a notification.
11. Trigger update check, ensure UI does not hang.

## Direct Distribution Checklist (Sparkle)

1. Ensure Sparkle feed is correct and signed.
2. Validate delta updates if enabled.
3. Validate notarization and stapling.
4. Ensure the script fails on notarization errors and prints the underlying tooling output.

Spec tie-in:
- `/.agent-docs/2026-02-07-macos-updates-controller-progress-ui.md`

## TestFlight / App Store Checklist

1. Confirm entitlements and sandbox settings (if applicable).
2. Ensure update UI does not refer to Sparkle when shipping via App Store.
3. Prepare App Store release notes from recent commits (separate changelog flow).

## "No Silent Failure" Script Spec

1. Any signing/notarization step must:
2. `set -euo pipefail`
3. Print the command that failed (or capture stderr to logs).
4. Exit non-zero on failure.

2. Notarization flows should surface:
1. Submission ID.
2. Final status.
3. Any rejection reasons.

## Acceptance Criteria

1. A new macOS beta build can be produced end-to-end without manual log spelunking.
2. Notarization failure is obvious and stops the release.
3. The shipped build does not regress core flows (login, messaging, notifications, update check).

## Open Questions

1. What is the target for "wider release": number of spaces/users, or just a clean beta?
2. Do we want a unified build that can operate in both channels, or separate build configurations?

