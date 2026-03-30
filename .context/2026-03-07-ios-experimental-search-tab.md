## Goal

Add a search tab to the iOS experimental root without changing the legacy iOS tab layout.

## Plan

1. Extend shared iOS tab routing with a dedicated `search` tab so experimental search keeps its own navigation stack.
2. Keep the legacy root on an explicit tab list so the new tab only appears in the experimental UI.
3. Add a focused experimental search view that reuses existing local/global search behavior without legacy toolbar content.
4. Match Apple's native search-tab structure more closely by making `TabView` the structural root, moving navigation stacks inside tabs, and using SwiftUI's explicit search-presentation binding as a fallback for pre-iOS 26 activation.
5. On iOS 26+, prefer SwiftUI's native search-tab activation with `tabViewSearchActivation(.searchTabSelection)` and keep the search root free of competing toolbar chrome.
6. Update experimental tab selection syncing and review the affected switch sites for compile safety.
