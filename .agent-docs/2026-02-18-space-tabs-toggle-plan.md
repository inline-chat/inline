# Space Tabs Toggle Plan (macOS)

## Goal
Reintroduce space tabs in the new macOS UI behind a View menu toggle (`Cmd+Shift+S`) using a pill-style strip above content.

## Tasks
- [x] 1. Add persisted setting `spaceTabsEnabled` in `AppSettings`.
- [x] 2. Add View menu item and hotkey in `AppMenu`, with checked state and toggle action.
- [x] 3. Implement new pill-style tabs strip UI bound to `Nav2`.
- [x] 4. Mount strip in `MainSplitView` and react to settings changes.
- [x] 5. Adjust message list top inset behavior to account for tabs strip height.
- [x] 6. Run focused build validation for macOS target/package and summarize risks.

## Validation
- Ran `cd apple/InlineMacUI && swift build` successfully.
- Build produced existing upstream warnings (SwiftProtobuf plugin deprecations and existing InlineKit warnings), but no new build failure from this change set.
- Final layout behavior: tabs strip now sits structurally above routed content in `MainSplitView` (content is constrained to tabs bottom), not as an overlay.
