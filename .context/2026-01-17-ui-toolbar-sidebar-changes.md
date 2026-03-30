# Changes to discard (2026-01-17)

## Files created
- apple/InlineMac/Features/Sidebar/NewMainSidebarView.swift
  - New SwiftUI sidebar implementation (header, action rows, chat list, archive toggle).
- apple/InlineMac/Features/Sidebar/NewMainSidebarViewModel.swift
  - New view model to provide mixed DM/thread list + archive filtering + spaces list.
- apple/InlineMac/Toolbar/TranslateButtion/TranslateToolbarAppKit.swift
  - AppKit-only translation toolbar button (no popover content).
- apple/InlineMac/Toolbar/Participants/ParticipantsToolbarAppKit.swift
  - AppKit-only participants toolbar button (no popover content; draws initials avatars).
- .agent-docs/2026-01-16-new-ui-sidebar-plan.md
  - Plan + status notes for the new UI/sidebar work.

## Files modified
- apple/InlineMac/Features/MainWindow/MainSplitView.swift
  - Commented out tab bar wiring and AppKit sidebar usage; content now anchors to top; new sidebar VC wired in.
- apple/InlineMac/Features/Toolbar/MainToolbar.swift
  - Toolbar wrapper is AppKit (stack view), and now uses AppKit toolbar item copies for translate/participants.
- apple/InlineMac/Toolbar/TranslateButtion/TranslateToolbar.swift
  - Added `.ignoresSafeArea()` on hosted SwiftUI translation button.
- apple/InlineMac/Toolbar/Participants/ParticipantsToolbar.swift
  - Added `.ignoresSafeArea()` on hosted SwiftUI participants button.

## Notes
- Repo has unrelated local changes outside these files (not touched by me).
- Let me know if you want me to revert only the files listed here, or everything including unrelated changes.
