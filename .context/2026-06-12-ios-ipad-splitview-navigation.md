# iOS iPad Split-View Navigation

Date: 2026-06-12

## Question

What would it take to support split-view navigation for the iOS app so it looks good on iPad, and can our tabs be used in the sidebar?

## Short Answer

Yes, our tabs can be used in the iPad sidebar.

The cleanest path is to build on the experimental iOS shell instead of the current production shell. The current production root uses legacy `TabView` plus `.tabItem` around one `NavigationStack` per app tab in `apple/InlineIOS/ContentView.swift:91`. The experimental root already uses the iOS 18 typed `Tab(...)` API in `apple/InlineIOS/ExperimentalRootView.swift:140`, which is the API shape needed for `.tabViewStyle(.sidebarAdaptable)`.

## Relevant APIs

- `NavigationSplitView` is available on iOS/iPadOS 16+ and is the right API for two- or three-column navigation.
- `Tab`, `TabSection`, and `.tabViewStyle(.sidebarAdaptable)` are available on iOS/iPadOS 18+.
- Our Apple minimums are iOS 18 and macOS 15, so we can use the iPad tab/sidebar API without adding older OS compatibility shims.

## Current State

- Production iOS root: `apple/InlineIOS/ContentView.swift`
  - `AuthedAppRoot` owns `legacyRootTabs = [.archived, .chats, .spaces]`.
  - It renders a `TabView(selection: $router.selectedTab)`.
  - Each tab is a `NavigationStack(path: $router[tab])`.
  - Destinations are pushed through the shared `Destination` enum.

- Experimental iOS root: `apple/InlineIOS/ExperimentalRootView.swift`
  - Uses typed `Tab("Archived", ...)`, `Tab("Chats", ...)`, and a search-role tab.
  - Keeps the app-level `Router` for per-tab paths and sheet presentation.
  - Has `ExperimentalNavigationModel`, which already owns `activeSpaceId`.

- Experimental chat list: `apple/InlineIOS/Features/Experimental/ExperimentalNavigation.swift`
  - `ExperimentalHomeView.openChat(_:)` currently does `router.push(.chat(peer: item.peerId))`.
  - For iPad split view, opening a chat should set selected detail state rather than only pushing into the tab path.

- Notification navigation: `apple/InlineIOS/Navigation/AppContent.swift`
  - `navigateFromNotification(peer:)` currently switches to `.chats`, pops the chat tab to root, then pushes `.chat(peer:)`.
  - Split-view support should update this to select the chat detail on iPad while preserving stack behavior in compact layouts.

## Recommended Shape

Use the experimental root as the base:

1. Add `.tabViewStyle(.sidebarAdaptable)` to the root `TabView`.
2. Keep tabs as app-level destinations: Chats, Archived, Search, and possibly Settings later.
3. Replace the chat tab root with a `NavigationSplitView`.
4. Keep the chat list in the leading/content column.
5. Render `ChatView` or an empty selection state in the detail column.
6. Keep `NavigationStack` inside detail for secondary routes like chat info, space settings, integrations, and create-thread flows.

The app should avoid creating two competing sidebars. The tab sidebar should be app-level navigation. The chat list should be the split-view list/content column.

## State Model Needed

The missing state is selected detail, not data loading.

Likely additions to `ExperimentalNavigationModel`:

```swift
var selectedPeer: Peer?
var selectedDetail: Destination?
```

or a narrower enum:

```swift
enum ExperimentalDetailSelection: Hashable, Codable {
  case chat(Peer)
  case space(Int64)
}
```

`activeSpaceId` can remain the source of truth for the selected space filter. Chat selection should be independent so a user can change the active space/list while the detail column updates predictably.

## Implementation Steps

1. Add sidebar-adaptable tabs to `ExperimentalAuthedRootView`.
   - Use `.tabViewStyle(.sidebarAdaptable)`.
   - Validate that iPhone still displays the bottom tab bar.

2. Introduce split-view selection state.
   - Add selected chat/detail state to `ExperimentalNavigationModel`.
   - Persist only if the UX should restore the last open chat on iPad. Otherwise keep it session-local.

3. Build an iPad split shell for Chats and Archived.
   - Shared chat list model can continue using `ExperimentalHomeView`/`ExperimentalChatListView`.
   - Tapping a row sets selected detail.
   - Detail column renders `ChatView(peer:contextSpaceId:autoCleanupUntitledEmptyThreadOnBack:)`.

4. Preserve compact behavior.
   - In compact width, `NavigationSplitView` collapses into a stack.
   - Use `preferredCompactColumn` if SwiftUI does not pick the desired column consistently.
   - Make sure back behavior on iPhone remains equivalent to the current push flow.

5. Update programmatic routing.
   - Notifications should select the chat in split mode.
   - Existing `router.push(.chat(peer:))` call sites should either keep compact behavior or route through a helper that chooses push vs selection depending on layout.

6. Verify secondary navigation.
   - Chat info, space settings, integrations, create space/chat/thread sheets should still work.
   - Detail-column pushes should not mutate the list selection unless that is intentional.

## Estimate

- First solid iPad version: 2 to 4 focused days.
- Polished version: about 1 week.

Polish includes search behavior, column visibility, empty states, keyboard shortcuts, portrait/landscape/Stage Manager checks, and notification/deep-link correctness.

## Risks And Tradeoffs

- The biggest risk is regressing iPhone collapse behavior. This needs explicit testing.
- The route model needs a small evolution from push-only navigation to selection plus detail stack.
- `.sidebarAdaptable` gives native tab/sidebar behavior quickly, but the UI hierarchy must avoid nested sidebars.
- We should prefer the experimental shell for this work because it already uses the modern iOS 18 tab API and has the right active-space state.

## Confidence

This is mostly app shell and router work, not backend or message rendering work. Existing chat list data loading and `ChatView` rendering can mostly remain intact. The part that needs careful review is navigation state consistency across iPad regular width, iPad compact/Slide Over, and iPhone.
