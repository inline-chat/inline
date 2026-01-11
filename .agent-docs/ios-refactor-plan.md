# iOS Refactor Plan (Performance + View Architecture)

Living plan. Append new findings as we review more files.

## Legend
- Status: backlog | in-progress | done
- Effort: S | M | L

## Findings (Performance)
1. Home lists resort/filter in computed properties each render (HomeView, SpaceView, SpacesView, ArchivedChatsView). Move sorting/filtering into view models or memoize on change. Evidence: `apple/InlineIOS/MainViews/HomeView.swift`, `apple/InlineIOS/Features/Space/SpaceView.swift`, `apple/InlineIOS/MainViews/SpacesView.swift`, `apple/InlineIOS/MainViews/ArchivedChatsView.swift`. Status: backlog. Effort: M.
2. List-wide implicit animations on data updates re-animate full list on frequent realtime changes. Scope animations to user actions only. Evidence: `apple/InlineIOS/Lists/ChatListView.swift`, `apple/InlineIOS/MainViews/ArchivedChatsView.swift`. Status: backlog. Effort: S.
3. Translation processing diff is O(n^2) and spawns detached task per update; use ID map + diff, throttle/cancel tasks, and avoid early `return` inside loop. Evidence: `apple/InlineIOS/Lists/ChatListView.swift`. Status: backlog. Effort: M.
4. Grouping by date recomputed on every access for documents/photos; cache in view model on data change. Evidence: `apple/InlineKit/Sources/InlineKit/ViewModels/ChatDocuments.swift`, `apple/InlineKit/Sources/InlineKit/ViewModels/ChatPhotos.swift`. Status: backlog. Effort: M.
5. DateFormatter allocations in hot paths; move to static cached formatters. Evidence: `apple/InlineIOS/Utils/Utils.swift`, `apple/InlineIOS/Features/ChatInfo/DocumentsTabView.swift`, `apple/InlineIOS/Features/ChatInfo/PhotosTabView.swift`, `apple/InlineIOS/Features/ChatInfo/ChatInfoView+extensions.swift`, `apple/InlineIOS/Features/Settings/SyncEngineStatsView.swift`. Status: backlog. Effort: S.
6. UploadProgressIndicator uses repeating Timer without invalidation; can run offscreen. Use TimelineView/async animation + cancel on disappear. Evidence: `apple/InlineIOS/UI/UploadProgressIndicator.swift`. Status: backlog. Effort: S.
7. Photo preview uses full-res UIImages across tabs; downsample/cache per screen size to reduce memory spikes. Evidence: `apple/InlineIOS/Features/Media/SwiftUIPhotoPreviewView.swift`, `apple/InlineIOS/Features/Media/PhotoPreviewView.swift`. Status: backlog. Effort: M.
8. ReactionsView sorts reactions each render; precompute in model or cache in view. Evidence: `apple/InlineIOS/Features/Reactions/ReactionsViewSwiftUI.swift`. Status: backlog. Effort: S.
9. Home search launches a new async search per keystroke without cancellation/debounce; overlapping requests can waste CPU/network and reorder results. Add debounced/cancellable search task. Evidence: `apple/InlineIOS/MainViews/HomeView.swift`. Status: backlog. Effort: S.
10. Search result relevance sorting runs inside computed properties on every render; precompute on query change instead of in `body`. Evidence: `apple/InlineIOS/MainViews/HomeView.swift`. Status: backlog. Effort: S.
11. MessagesCollectionView performs linear scans to find index paths; if used frequently, maintain an id→IndexPath map to avoid O(n) lookups. Evidence: `apple/InlineIOS/Features/Chat/MessagesCollectionView.swift`. Status: backlog. Effort: M.

## Findings (Simplify Views)
1. ChatInfoView body is large and mixes data loading, tab UI, and content rendering; split into header, tab bar, and content subviews/structs. Evidence: `apple/InlineIOS/Features/ChatInfo/ChatInfoView.swift`. Status: backlog. Effort: M.
2. HomeView combines search, list, networking, and navigation handling in one file; split search logic into view model and move search result row to dedicated view. Evidence: `apple/InlineIOS/MainViews/HomeView.swift`. Status: backlog. Effort: M.
3. ArchivedChatsView has large inline list with swipe actions; extract row + actions into reusable component (shared with ChatListView). Evidence: `apple/InlineIOS/MainViews/ArchivedChatsView.swift`. Status: backlog. Effort: M.
4. SpacesView header logic duplicated in ArchivedChatsView; extract a shared connection-status header view. Evidence: `apple/InlineIOS/MainViews/SpacesView.swift`, `apple/InlineIOS/MainViews/ArchivedChatsView.swift`. Status: backlog. Effort: S.
5. ComposeView is doing text input, attachment handling, overlay management, and networking hooks in one class; split into focused subcomponents. Evidence: `apple/InlineIOS/Features/Compose/ComposeView.swift`. Status: backlog. Effort: M.
6. MessagesCollectionView is a very large class (layout, data source, scrolling, notifications); extract coordinator/data source/behavior helpers. Evidence: `apple/InlineIOS/Features/Chat/MessagesCollectionView.swift`. Status: backlog. Effort: M.
7. UIMessageView mixes layout, parsing, media, reactions, and interactions; split into dedicated subviews for text/media/reactions. Evidence: `apple/InlineIOS/Features/Message/UIMessageView.swift`. Status: backlog. Effort: M.
8. DocumentView is a large UIKit view with state machine + UI + download logic; split view from state/IO. Evidence: `apple/InlineIOS/Features/Media/DocumentView.swift`. Status: backlog. Effort: M.
9. ComposeTextView contains placeholder, attachment detection, and paste logic; consider extracting attachment parsing or delegate helpers. Evidence: `apple/InlineIOS/Features/Compose/ComposeTextView.swift`. Status: backlog. Effort: S.

## Findings (Best Practices)
1. Avoid `Task.detached` for UI-driven work unless isolation is required; prefer `Task {}` and explicit actor hops for UI updates. Evidence: `apple/InlineIOS/MainViews/HomeView.swift`, `apple/InlineIOS/Lists/ChatListView.swift`, `apple/InlineKit/Sources/InlineKit/ViewModels/HomeViewModel.swift`. Status: backlog. Effort: S.
2. Remove debug `print` in production view code. Evidence: `apple/InlineIOS/Features/ChatInfo/ChatInfoView+extensions.swift`. Status: backlog. Effort: S.
3. Consolidate repeated date formatting logic into shared helper to avoid drift and unnecessary allocations. Evidence: `apple/InlineIOS/Utils/Utils.swift`, `apple/InlineIOS/Features/ChatInfo/DocumentsTabView.swift`, `apple/InlineIOS/Features/ChatInfo/PhotosTabView.swift`, `apple/InlineIOS/Features/ChatInfo/ChatInfoView+extensions.swift`. Status: backlog. Effort: S.
4. HomeView injects the same `DataManager` twice (`dataManager` and `data`); remove duplication to reduce ambiguity. Evidence: `apple/InlineIOS/MainViews/HomeView.swift`. Status: backlog. Effort: S.
5. Avoid `.id(selectedSegment)` to force view recreation; prefer explicit state handling to prevent unnecessary rebuilds. Evidence: `apple/InlineIOS/Features/Space/SpaceView.swift`. Status: backlog. Effort: S.
6. Replace `NavigationView` with `NavigationStack` in sheets (modern SwiftUI best practice). Evidence: `apple/InlineIOS/UI/NotificationSettingsPopover.swift`. Status: backlog. Effort: S.

## Findings (Unused Views)
1. PhotosTabView appears unused (no references found). Confirm removal or reintegration. Evidence: `apple/InlineIOS/Features/ChatInfo/PhotosTabView.swift`. Status: backlog. Effort: S.
2. PhotoPreviewView appears unused (no references found). Confirm removal or reintegration. Evidence: `apple/InlineIOS/Features/Media/PhotoPreviewView.swift`. Status: backlog. Effort: S.
3. EmptyHomeView appears unused (no references found). Confirm removal or reintegration. Evidence: `apple/InlineIOS/UI/EmptyState/EmptyHomeView.swift`. Status: backlog. Effort: S.
4. SwipeBackModifier appears unused (no references found). Confirm removal or reintegration. Evidence: `apple/InlineIOS/UI/SwipeBackModifier.swift`. Status: backlog. Effort: S.
5. GlassyActionButton (PrimaryButton) appears unused (no references found). Confirm removal or reintegration. Evidence: `apple/InlineIOS/UI/PrimaryButton.swift`. Status: backlog. Effort: S.
6. TabBarController appears unused (no references found). Confirm removal or reintegration. Evidence: `apple/InlineIOS/UI/TabBarController.swift`. Status: backlog. Effort: S.

## Findings (Break Down Views)
1. ChatListView could be split into list container + row view + swipe action builders for reuse and to reduce body size. Evidence: `apple/InlineIOS/Lists/ChatListView.swift`. Status: backlog. Effort: S.
2. ChatListItem combines avatar/title/subtitle/unread; consider splitting into smaller subviews for clearer updates (title/subtitle/unread). Evidence: `apple/InlineIOS/Lists/ChatListItem.swift`. Status: backlog. Effort: S.
3. SwiftUIPhotoPreviewView is large (layout + gestures + overlays). Extract zoom/pan image view and bottom controls to reduce recomposition cost. Evidence: `apple/InlineIOS/Features/Media/SwiftUIPhotoPreviewView.swift`. Status: backlog. Effort: M.
4. ComposeView should be decomposed into text input, attachments, and overlay components for clarity and testing. Evidence: `apple/InlineIOS/Features/Compose/ComposeView.swift`. Status: backlog. Effort: M.
5. MessagesCollectionView should be split into layout/data source/interaction helpers to limit surface area. Evidence: `apple/InlineIOS/Features/Chat/MessagesCollectionView.swift`. Status: backlog. Effort: M.
6. UIMessageView should be broken into message content + metadata + reactions subviews to reduce update scope. Evidence: `apple/InlineIOS/Features/Message/UIMessageView.swift`. Status: backlog. Effort: M.
7. DocumentView should be split into state/IO + pure view. Evidence: `apple/InlineIOS/Features/Media/DocumentView.swift`. Status: backlog. Effort: M.
8. ChatViewUIKit should be split into container layout, compose handling, and message list coordination. Evidence: `apple/InlineIOS/Features/Chat/ChatViewUIKit.swift`. Status: backlog. Effort: M.

## Findings (macOS Performance)
1. Synchronous `NSImage(contentsOf:)` usage can block the main thread when loading local media; move decoding off-main or use Nuke pipeline. Evidence: `apple/InlineMac/Views/Message/Media/PhotoView.swift`, `apple/InlineMac/Views/Compose/ComposeAttachments.swift`, `apple/InlineMac/Views/Compose/ComposeMenuButton.swift`, `apple/InlineMac/Views/Compose/ComposeAppKit.swift`, `apple/InlineMac/Views/Compose/Pasteboard.swift`, `apple/InlineMac/Views/ImageCache/ImageCacheManager.swift`. Status: backlog. Effort: M.
2. Message list rebuild + height recalculation is expensive on large chats; ensure diff-only updates and cached heights are used on incremental changes. Evidence: `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`, `apple/InlineMac/Views/MessageList/MessageSizeCalculator.swift`. Status: backlog. Effort: M.

## Findings (macOS Simplify Views)
1. MessageViewAppKit is very large (layout, media, reactions, interactions); split into focused subviews. Evidence: `apple/InlineMac/Views/Message/MessageView.swift`. Status: backlog. Effort: M.
2. MessageListAppKit mixes data flow, layout, translation, and scroll behavior; split into data source + layout + interaction layers. Evidence: `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`. Status: backlog. Effort: M.
3. ComposeAppKit owns text editing, attachments, and send logic; split into editor + attachments + toolbar components. Evidence: `apple/InlineMac/Views/Compose/ComposeAppKit.swift`. Status: backlog. Effort: M.
4. SidebarItemRow is large and state-heavy; split into avatar/title/badge subviews. Evidence: `apple/InlineMac/Views/Sidebar/NewSidebar/SidebarItemRow.swift`. Status: backlog. Effort: M.
5. DocumentView mixes state machine + UI + download; split IO from view. Evidence: `apple/InlineMac/Views/DocumentView/DocumentView.swift`. Status: backlog. Effort: M.

## Findings (macOS Best Practices)
1. Prefer structured tasks with cancellation over `Task.detached` in view/controller code. Evidence: `apple/InlineMac/Views/Compose/ComposeAppKit.swift`, `apple/InlineMac/Views/Main/MainSplitViewAppKit.swift`, `apple/InlineMac/Features/TabBar/MainTabBar.swift`, `apple/InlineMac/Views/Sidebar/NewSidebar/NewSidebar.swift`, `apple/InlineMac/Views/Sidebar/MainSidebar/SpaceSidebar.swift`, `apple/InlineMac/Views/Message/Media/NewPhotoView.swift`, `apple/InlineMac/Views/Message/Media/NewVideoView.swift`, `apple/InlineMac/Views/EmbeddedMessage/SimplePhotoView.swift`. Status: backlog. Effort: S.

## Findings (macOS Unused Views)
1. CustomTooltip appears unused (no references found). Confirm removal or reintegration. Evidence: `apple/InlineMac/Views/Common/CustomTooltip.swift`. Status: backlog. Effort: S.

## Findings (macOS Break Down Views)
1. MessageViewAppKit should be decomposed into media/text/reaction subviews to reduce layout churn. Evidence: `apple/InlineMac/Views/Message/MessageView.swift`. Status: backlog. Effort: M.
2. MessageListAppKit should be split into data source, layout, and translation handlers. Evidence: `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`. Status: backlog. Effort: M.
3. ComposeAppKit should be separated into editor, attachments, and menu controllers. Evidence: `apple/InlineMac/Views/Compose/ComposeAppKit.swift`. Status: backlog. Effort: M.
4. SidebarItemRow should be broken into subviews for easier updates. Evidence: `apple/InlineMac/Views/Sidebar/NewSidebar/SidebarItemRow.swift`. Status: backlog. Effort: M.

## Next steps
- Append new findings here as we review more views.
- Confirm unused views with product before deletion.
