# Tomorrow Prep Index (2026-02-07)

Source: Obsidian daily notes from **February 1st to February 7th, 2026**.

This is planning + research only. Deliverable is one spec per item so we can implement quickly tomorrow.

Scope note: this covers Inline/product/engineering items. Personal TODOs (bills, gifts, etc.) are intentionally excluded.

## Priority Order For Tomorrow

1. iOS "auto logout" (router/auth hydration) hotfix.
2. Sync reliability: remove gaps + sane TOO_LONG recovery.
3. Chat open speed + pagination + go-to-message reliability (iOS + macOS).
4. Notifications: title correctness, clearing, per-chat settings spec.
5. Multi-space workflow + space picker polish + move thread to/out of space.
6. CLI ergonomics: consistent JSON mode + action tests.
7. Compose "silent send" toggle (sleep-time calm).
8. macOS rename UX polish (dbl click/Return, constraints).
9. macOS window controls: always-on-top persistence + show on all spaces, plus global hotkey reliability.
10. macOS update UX/controller (Sparkle driver + progress surfaces).
11. macOS non-bubble message view (feature-flagged).
12. Subthreads spec (backlinks, access control, discoverability).
13. Bots/SDK spec (CLI-based bots + updates thread concept).
14. Archive mode UX fixes (ESC closes, repeated actions).

## Specs (One Per Item)

- `/.agent-docs/2026-02-07-ios-auto-logout-router-auth2-hotfix.md`
- `/.agent-docs/2026-02-07-sync-reliability-gap-repair.md`
- `/.agent-docs/2026-02-07-chat-open-perf-pagination-go-to-message.md`
- `/.agent-docs/2026-02-07-notifications-title-clearing-per-chat-settings.md`
- `/.agent-docs/2026-02-07-multi-space-workflow-space-picker-move-thread.md`
- `/.agent-docs/2026-02-07-cli-ergonomics-json-mode-tests.md`
- `/.agent-docs/2026-02-07-compose-silent-send-toggle.md`
- `/.agent-docs/2026-02-07-macos-rename-thread-title-ux.md`
- `/.agent-docs/2026-02-07-macos-window-controls-hotkey-always-on-top-all-spaces.md`
- `/.agent-docs/2026-02-07-macos-updates-controller-progress-ui.md`
- `/.agent-docs/2026-02-07-macos-non-bubble-message-view.md`
- `/.agent-docs/2026-02-07-subthreads-backlinks-access-control-discovery.md`
- `/.agent-docs/2026-02-07-bots-sdk-and-updates-thread.md`
- `/.agent-docs/2026-02-07-archive-mode-ux-fixes.md`

## Additional Backlog Specs (Also Prepared)

These map to the remaining Feb 1-7 TODOs so tomorrow can be “pick one and ship”.

- `/.agent-docs/2026-02-07-search-across-everything-spec.md`
- `/.agent-docs/2026-02-07-macos-avatar-and-media-flicker-fix-plan.md`
- `/.agent-docs/2026-02-07-ios-memory-background-jetsam-investigation.md`
- `/.agent-docs/2026-02-07-mentions-auto-add-policy-and-mention-indicators.md`
- `/.agent-docs/2026-02-07-macos-new-ui-polish-batch.md`
- `/.agent-docs/2026-02-07-macos-sidebar-initial-load-perf.md`
- `/.agent-docs/2026-02-07-macos-message-send-latency.md`
- `/.agent-docs/2026-02-07-macos-reactions-toggle-and-resize-bugs.md`
- `/.agent-docs/2026-02-07-pinned-messages-stable-fetch-navigate-flicker.md`
- `/.agent-docs/2026-02-07-deep-links-space-thread-message.md`
- `/.agent-docs/2026-02-07-new-thread-flow-polish-and-ai-title.md`
- `/.agent-docs/2026-02-07-ios-ui-per-space-compact-thread-archive.md`
- `/.agent-docs/2026-02-07-macos-back-forward-navigation.md`
- `/.agent-docs/2026-02-07-macos-launch-at-login-loading-ui.md`
- `/.agent-docs/2026-02-07-in-app-alerts-replace-telegram.md`
- `/.agent-docs/2026-02-07-nudge-usage-measurement-and-removal.md`
- `/.agent-docs/2026-02-07-notification-settings-ui-fixes.md`
- `/.agent-docs/2026-02-07-repo-hygiene-and-macos-modularization.md`
- `/.agent-docs/2026-02-07-macos-release-testflight-direct-distribution-checklist.md`
- `/.agent-docs/2026-02-07-cli-release-checklist.md`
- `/.agent-docs/2026-02-07-codex-skills-90-10-prevent-tech-debt-lets-work-together.md`
- `/.agent-docs/2026-02-07-notes-todo-coverage-map.md`
- `/.agent-docs/2026-02-07-home-threads-support-and-move-wakawars.md`
- `/.agent-docs/2026-02-07-macos-forward-submenu-and-hover-actions.md`
- `/.agent-docs/2026-02-07-macos-save-media-wait-for-download.md`
- `/.agent-docs/2026-02-07-macos-toolbar-traffic-lights-background.md`

## Suggested "Tomorrow Morning" Execution Loop

1. Pick item 1-3 and implement with tight feedback loops.
2. After each item: run the smallest relevant tests; do one focused manual smoke test on macOS + iOS.
3. Avoid big cross-cutting refactors unless the spec calls it out explicitly.

## Quick Commands (When Implementing)

- InlineKit tests: `cd apple/InlineKit && swift test`
- Server tests: `cd server && bun test`
- Web typecheck: `cd web && bun run typecheck`
- CLI tests: `cd cli && cargo test`
