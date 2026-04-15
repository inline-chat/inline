## Core Decisions

- We're refactoring the macOS experimental UI.
- We intend to move from our own custom split view and toolbars to native split view and toolbars.
- We will keep the root of the window in AppKit.
- We will use the latest AppKit/SwiftUI/Swift APIs and best practices for macOS 26 as enhancements while supporting macOS 15 (eg. new glass toolbar styling methods).

## Split View

We will use `NSSplitViewController`. Our current custom split view will no longer be used, along with our current space picker tab bar.

The space picker should integrate with the native sidebar so scrolling and material behave correctly. The sidebar's collection view or scroll view should fill the whole height of the sidebar while preserving correct insets.

## Toolbar

For our legacy macOS UI we were using `NSToolbar`. That's great, but we should not just copy-paste that. We should create a new `NSToolbar` view controller for our experimental UI window which will host our navigation buttons, chat title bar, translation, notification setting, participants, and the new chat menu item.

It should remain usable for other routes such as chat info if possible, using interop with SwiftUI toolbar APIs (check Apple docs) or via custom APIs. That is not part of this batch of changes.

## Future Multi-Window / Multi-Tabs Work

After the core of the changes are in place we intend to ship native multi-tab support to open multiple chats, and/or multiple windows.
