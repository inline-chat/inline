import Auth
import InlineKit
import InlineUI
import Invite
import Logger
import RealtimeV2
import SwiftUI
import UIKit

@MainActor
@Observable
final class ExperimentalNavigationModel {
  private static let activeSpaceDefaultsKey = "activeSpaceId"
  private var didRunHomeBootstrap = false
  private var fetchedDialogSpaceIds = Set<Int64>()
  private var fetchingDialogSpaceIds = Set<Int64>()

  private(set) var homeRefreshRevision = 0

  var activeSpaceId: Int64? {
    didSet {
      guard oldValue != activeSpaceId else { return }
      homeRefreshRevision += 1
    }
  }

  init(activeSpaceId: Int64? = nil) {
    self.activeSpaceId = activeSpaceId
  }

  func consumeNeedsHomeBootstrap() -> Bool {
    guard !didRunHomeBootstrap else { return false }
    didRunHomeBootstrap = true
    return true
  }

  func beginDialogsFetchIfNeeded(spaceId: Int64, force: Bool = false) -> Bool {
    guard force || !fetchedDialogSpaceIds.contains(spaceId) else { return false }
    return fetchingDialogSpaceIds.insert(spaceId).inserted
  }

  func completeDialogsFetch(
    spaceId: Int64,
    succeeded: Bool
  ) {
    fetchingDialogSpaceIds.remove(spaceId)
    if succeeded {
      fetchedDialogSpaceIds.insert(spaceId)
    }
  }

  func pruneDialogFetchState(validSpaceIds: Set<Int64>) {
    fetchedDialogSpaceIds = fetchedDialogSpaceIds.filter { validSpaceIds.contains($0) }
    fetchingDialogSpaceIds = fetchingDialogSpaceIds.filter { validSpaceIds.contains($0) }
  }

  func resetHomeDataState() {
    didRunHomeBootstrap = false
    fetchedDialogSpaceIds.removeAll()
    fetchingDialogSpaceIds.removeAll()
    homeRefreshRevision += 1
  }

  static func loadLegacyActiveSpaceId() -> Int64? {
    let defaults = UserDefaults.standard

    if let value = defaults.object(forKey: activeSpaceDefaultsKey) as? Int64 {
      return value
    }
    if let value = defaults.object(forKey: activeSpaceDefaultsKey) as? Int {
      return Int64(value)
    }
    if let value = defaults.object(forKey: activeSpaceDefaultsKey) as? NSNumber {
      return value.int64Value
    }
    return nil
  }
}

@MainActor
enum ExperimentalHomeNavigationPerformance {
  private struct PendingChatOpen {
    let span: PerformanceTrace.Span
    let startedAt: Date
  }

  private static var pendingChatOpens: [Peer: PendingChatOpen] = [:]

  static func beginChatOpen(peer: Peer, source: String) {
    if let replaced = pendingChatOpens.removeValue(forKey: peer) {
      replaced.span.end("result=replaced")
    }
    pendingChatOpens[peer] = PendingChatOpen(
      span: PerformanceTrace.begin(
        "HomeChatOpen",
        category: .home,
        "source=\(source)"
      ),
      startedAt: Date()
    )
  }

  static func completeChatOpen(peer: Peer) {
    guard let pending = pendingChatOpens.removeValue(forKey: peer) else { return }
    let durationMs = PerformanceTrace.elapsedMilliseconds(since: pending.startedAt)
    pending.span.end("duration_ms=\(durationMs)")
    PerformanceTrace.slowBreadcrumb(
      "iOS Home chat navigation was slow",
      category: "ios.home.navigation.chat",
      durationMs: durationMs,
      thresholdMs: 100
    )
  }

  static func measureTabSwitch(from: String, to: String, rows: Int) {
    let startedAt = Date()
    let span = PerformanceTrace.begin(
      "HomeTabSwitch",
      category: .home,
      "from=\(from) to=\(to) rows=\(rows)"
    )
    Task { @MainActor in
      await Task.yield()
      let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
      span.end("duration_ms=\(durationMs)")
      PerformanceTrace.slowBreadcrumb(
        "iOS Home tab switch was slow",
        category: "ios.home.navigation.tab",
        durationMs: durationMs,
        thresholdMs: 100,
        data: ["from": from, "to": to, "rows": rows]
      )
    }
  }

  static func measureBackToHome(rows: Int) {
    let startedAt = Date()
    let span = PerformanceTrace.begin(
      "HomeBackNavigation",
      category: .home,
      "rows=\(rows)"
    )
    Task { @MainActor in
      await Task.yield()
      let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
      span.end("duration_ms=\(durationMs)")
      PerformanceTrace.slowBreadcrumb(
        "iOS back navigation to Home was slow",
        category: "ios.home.navigation.back",
        durationMs: durationMs,
        thresholdMs: 100,
        data: ["rows": rows]
      )
    }
  }
}

struct ExperimentalDestinationView: View {
  @Bindable var nav: ExperimentalNavigationModel
  let destination: Destination
  var usesRouterNavigation = false
  let onSelectSpace: (Int64) -> Void
  let onMigrateLegacySpaceDestination: (Int64) -> Void

  var body: some View {
    content
  }

  @ViewBuilder
  private var content: some View {
    switch destination {
    case .chats:
      ExperimentalHomeView(initialTab: .inbox)
    case .archived:
      ExperimentalHomeView(initialTab: .archived)
    case .spaces:
      SpacesView()
    case let .space(id):
      LegacySpaceDestinationRedirect(
        spaceID: id,
        onRedirect: onMigrateLegacySpaceDestination
      )
    case let .chat(peer):
      ChatView(
        peer: peer,
        contextSpaceId: nav.activeSpaceId,
        onOpenSpace: onSelectSpace,
        autoCleanupUntitledEmptyThreadOnBack: true
      )
      .id(peer)
      .onAppear {
        ExperimentalHomeNavigationPerformance.completeChatOpen(peer: peer)
      }
    case let .externalChat(peer, contextSpaceID, messageID):
      ChatView(
        peer: peer,
        contextSpaceId: contextSpaceID,
        onOpenSpace: onSelectSpace,
        focusMessageID: messageID,
        autoCleanupUntitledEmptyThreadOnBack: true
      )
      .id(peer)
      .onAppear {
        if nav.activeSpaceId != contextSpaceID {
          nav.activeSpaceId = nil
        }
        ExperimentalHomeNavigationPerformance.completeChatOpen(peer: peer)
      }
    case let .chatMessage(peer, messageID):
      ChatView(
        peer: peer,
        contextSpaceId: nav.activeSpaceId,
        onOpenSpace: onSelectSpace,
        focusMessageID: messageID,
        autoCleanupUntitledEmptyThreadOnBack: true
      )
      .id(peer)
      .onAppear {
        ExperimentalHomeNavigationPerformance.completeChatOpen(peer: peer)
      }
    case let .chatInfo(chatItem):
      ChatInfoView(chatItem: chatItem)
    case let .spaceSettings(spaceId):
      SpaceSettingsView(spaceId: spaceId, usesRouterNavigation: usesRouterNavigation)
    case let .spaceIntegrations(spaceId):
      SpaceIntegrationsView(spaceId: spaceId)
    case let .integrationOptions(spaceId, provider):
      IntegrationOptionsView(spaceId: spaceId, provider: provider)
    case .createSpaceChat:
      CreateChatView(spaceId: nil)
    case let .createThread(spaceId):
      CreateChatView(spaceId: spaceId)
    case .createSpace:
      CreateSpaceView(onCreated: onSelectSpace)
    }
  }
}

struct ExperimentalSheetView: View {
  let sheet: Sheet
  let onSelectSpace: (Int64) -> Void
  @Environment(Router.self) private var router

  var body: some View {
    switch sheet {
    case .settings:
      NavigationStack {
        SettingsView(onSelectSpace: onSelectSpace)
      }
    case let .connectors(callbackURL):
      NavigationStack {
        ConnectorsView(initialOAuthCallbackURL: URL(string: callbackURL))
      }
    case .createSpace:
      CreateSpace(onCreated: onSelectSpace)
    case let .addMember(spaceId):
      InviteView(
        destination: .space(id: spaceId),
        onCreateSpace: { router.presentSheet(.createSpace) }
      )
    case .inviteToInline:
      InviteView(
        destination: .inline,
        onOpenChat: { peer in
          router.dismissSheet()
          router.openPrimaryDestination(.chat(peer: peer))
        },
        onCreateSpace: { router.presentSheet(.createSpace) }
      )
    case let .members(spaceId):
      ExperimentalMembersSheetView(spaceId: spaceId)
    case let .chatInfo(chatItem):
      NavigationStack {
        ChatInfoView(chatItem: chatItem)
      }
    }
  }
}

// MARK: - Home

enum ExperimentalHomeTab: Hashable {
  case inbox
  case allChats
  case archived
}

struct ExperimentalHomeView: View {
  let initialTab: ExperimentalHomeTab
  var allChatsFilter: ChatListFilter = .all
  private let selection: Binding<Destination?>?

  @AppStorage private var pinnedExpanded: Bool

  @EnvironmentObject private var homeListStore: ExperimentalHomeListStore
  @EnvironmentObject private var themeManager: ThemeManager

  @AppStorage(ExperimentalHomePreferenceKeys.chatItemRenderMode)
  private var chatItemRenderModeRaw = ExperimentalHomeChatItemRenderMode.twoLineLastMessage.rawValue

  @AppStorage(ExperimentalHomePreferenceKeys.unreadBadgeStyle)
  private var unreadBadgeStyleRawValue = ExperimentalHomeUnreadBadgeStyle.defaultValue.rawValue

  init(
    initialTab: ExperimentalHomeTab,
    allChatsFilter: ChatListFilter = .all,
    selection: Binding<Destination?>? = nil
  ) {
    self.initialTab = initialTab
    self.allChatsFilter = allChatsFilter
    self.selection = selection
    let surface: ExperimentalHomePinnedSurface = initialTab == .allChats ? .allChats : .inbox
    _pinnedExpanded = AppStorage(
      wrappedValue: true,
      ExperimentalHomePreferenceKeys.pinnedExpanded(
        surface: surface,
        userID: Auth.shared.getCurrentUserId()
      )
    )
  }

  var body: some View {
    Group {
      switch initialTab {
      case .inbox:
        ExperimentalChatListView(
          items: homeListStore.state.presentation.inboxUnpinned,
          pinnedItems: homeListStore.state.presentation.inboxPinned,
          timelineSections: [],
          daySections: [],
          mode: .inbox,
          emptyStyle: .inlineLogo,
          emptyTitle: "No open chats",
          emptySubtitle: "Open a chat from All Chats to keep it here.",
          chatItemRenderMode: chatItemRenderMode,
          unreadBadgeStyle: unreadBadgeStyle,
          isLoading: homeListStore.state.isLoading,
          status: homeStatus,
          pinnedExpanded: $pinnedExpanded,
          selection: selection
        )
      case .allChats:
        ExperimentalChatListView(
          items: [],
          pinnedItems: homeListStore.state.presentation.allChatsPinned,
          timelineSections: homeListStore.state.presentation.allChatSections,
          daySections: [],
          mode: .allChats,
          emptyStyle: allChatsFilter == .unread ? .unreadFilter : .inlineLogo,
          emptyTitle: allChatsFilter == .unread ? "No unread chats" : "No chats",
          emptySubtitle: allChatsFilter == .unread
            ? "You’re caught up."
            : "Start a new thread with the plus button.",
          chatItemRenderMode: chatItemRenderMode,
          unreadBadgeStyle: unreadBadgeStyle,
          isLoading: homeListStore.state.isLoading,
          status: homeStatus,
          pinnedExpanded: $pinnedExpanded,
          selection: selection
        )
      case .archived:
        ExperimentalChatListView(
          items: [],
          pinnedItems: [],
          timelineSections: [],
          daySections: homeListStore.state.presentation.archivedSections,
          mode: .archived,
          emptyStyle: .text,
          emptyTitle: "No archived chats",
          emptySubtitle: "Archived chats will show up here.",
          chatItemRenderMode: chatItemRenderMode,
          unreadBadgeStyle: unreadBadgeStyle,
          isLoading: homeListStore.state.isLoading,
          status: homeStatus,
          pinnedExpanded: $pinnedExpanded
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(homeCanvas)
    .navigationBarTitleDisplayMode(.inline)
    .navigationTitle(initialTab == .archived ? Text("Archived Chats") : Text(""))
  }

  private var homeCanvas: Color {
    Color(themeManager.selected.backgroundColor)
  }

  private var chatItemRenderMode: ExperimentalHomeChatItemRenderMode {
    ExperimentalHomeChatItemRenderMode(rawValue: chatItemRenderModeRaw) ?? .twoLineLastMessage
  }

  private var unreadBadgeStyle: ExperimentalHomeUnreadBadgeStyle {
    ExperimentalHomeUnreadBadgeStyle(rawValue: unreadBadgeStyleRawValue) ?? .defaultValue
  }

  private var homeStatus: ExperimentalHomeStatus? {
    // A valid local snapshot includes zero rows. Remote refresh health is reported
    // separately and must never replace that snapshot with cache-failure UI.
    if homeListStore.state.errorDescription != nil {
      return .error("Chats stored on this device could not be read.")
    }
    return nil
  }

}

private enum ExperimentalChatListMode: Equatable {
  case inbox
  case allChats
  case archived
}

private enum ExperimentalHomeStatus: Equatable {
  case error(String)
}

private struct ExperimentalChatListView: View {
  enum EmptyStyle {
    case text
    case inlineLogo
    case unreadFilter
  }

  let items: [ChatListItemSnapshot]
  let pinnedItems: [ChatListItemSnapshot]
  let timelineSections: [ChatListTimelineSection]
  let daySections: [ChatListDaySection]
  let mode: ExperimentalChatListMode
  let emptyStyle: EmptyStyle
  let emptyTitle: String
  let emptySubtitle: String
  let chatItemRenderMode: ExperimentalHomeChatItemRenderMode
  let unreadBadgeStyle: ExperimentalHomeUnreadBadgeStyle
  let isLoading: Bool
  let status: ExperimentalHomeStatus?
  @Binding var pinnedExpanded: Bool
  var selection: Binding<Destination?>?

  @EnvironmentObject private var data: DataManager
  @EnvironmentObject private var themeManager: ThemeManager
  @EnvironmentObject private var notificationSettings: NotificationSettingsManager
  @EnvironmentObject private var realtimeState: RealtimeState
  @Environment(Router.self) private var router
  @Environment(\.appDatabase) private var appDatabase
  @Environment(\.realtimeV2) private var realtimeV2
  @Environment(ExperimentalHomeActionCoordinator.self) private var homeActions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pendingArchiveItem: ChatListItemSnapshot?

  var body: some View {
    Group {
      if isLoading && isEmpty {
        ExperimentalLoadingStateView()
      } else if isEmpty, case let .error(message) = status {
        ExperimentalHomeFailureStateView(message: message)
      } else if isEmpty {
        emptyContent
      } else {
        chatList
      }
    }
    .alert(
      "Archive Chat?",
      isPresented: Binding(
        get: { pendingArchiveItem != nil },
        set: { if !$0 { pendingArchiveItem = nil } }
      ),
      presenting: pendingArchiveItem
    ) { item in
      Button("Archive", role: .destructive) {
        pendingArchiveItem = nil
        performArchive(item)
      }
      Button("Cancel", role: .cancel) {
        pendingArchiveItem = nil
      }
    } message: { _ in
      Text("This chat will move to Archived Chats. You can find it from the ••• menu.")
    }
  }

  @ViewBuilder
  private var chatList: some View {
    if let selection {
      styledList {
        List(selection: selection) {
          listRows
        }
      }
    } else {
      // Keep the phone construction as the original plain List. An absent iPad
      // selection binding must not opt the phone surface into selection behavior.
      styledList {
        List {
          listRows
        }
      }
    }
  }

  @ViewBuilder
  private var listRows: some View {
    if !pinnedItems.isEmpty {
      ExperimentalPinnedChatSection(
        isExpanded: $pinnedExpanded,
        chatItemRenderMode: chatItemRenderMode,
        headerInsets: sectionHeaderInsets
      ) {
        rows(for: pinnedItems)
      }
    }

    if mode == .allChats {
      ForEach(timelineSections) { section in
        Section {
          ExperimentalChatTimelineSectionHeader(
            period: section.id,
            chatItemRenderMode: chatItemRenderMode
          )
            .listRowInsets(sectionHeaderInsets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

          rows(for: section.items)
        }
      }
    } else if mode == .archived {
      ForEach(daySections) { section in
        Section {
          ExperimentalChatDaySectionHeader(
            day: section.id,
            chatItemRenderMode: chatItemRenderMode
          )
            .listRowInsets(sectionHeaderInsets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

          rows(for: section.items)
        }
      }
    } else if mode == .inbox {
      ForEach(inboxSections) { section in
        Section {
          ExperimentalChatSectionHeader(
            title: section.title,
            chatItemRenderMode: chatItemRenderMode
          )
            .listRowInsets(sectionHeaderInsets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

          rows(for: section.items)
        }
      }
    } else {
      rows(for: items)
    }
  }

  private func styledList<Content: View>(
    @ViewBuilder _ content: () -> Content
  ) -> some View {
    content()
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .background(Color.clear)
      .contentMargins(.top, listTopContentMargin, for: .scrollContent)
      .contentMargins(.bottom, 32, for: .scrollContent)
      .listSectionSpacing(.custom(listSectionSpacing))
      .environment(\.defaultMinListRowHeight, defaultMinimumListRowHeight)
      .animation(
        mode == .inbox ? .snappy(duration: 0.25, extraBounce: 0) : nil,
        value: animatedInboxRows
      )
      .animation(
        reduceMotion ? nil : .smooth(duration: 0.18),
        value: pinnedExpanded
      )
  }

  /// A focused animation trigger for Inbox membership and ordering changes.
  /// Content updates keep the same identity sequence and do not animate.
  private var animatedInboxRows: [InboxRowLocation] {
    guard mode == .inbox else { return [] }
    return pinnedItems.map { InboxRowLocation(peer: $0.peer, section: .pinned) }
      + items.map { InboxRowLocation(peer: $0.peer, section: .inbox) }
  }

  private var isEmpty: Bool {
    items.isEmpty && pinnedItems.isEmpty && timelineSections.isEmpty && daySections.isEmpty
  }

  @ViewBuilder
  private var emptyContent: some View {
    switch emptyStyle {
    case .text:
      ExperimentalEmptyStateView(title: emptyTitle, subtitle: emptySubtitle)
    case .inlineLogo:
      ExperimentalInlineLogoEmptyStateView()
    case .unreadFilter:
      ContentUnavailableView(
        emptyTitle,
        systemImage: "checkmark.message",
        description: Text(emptySubtitle)
      )
    }
  }

  private var sectionHeaderInsets: EdgeInsets {
    EdgeInsets(
      top: 1,
      leading: Theme.Layout.screenEdgeOpticalInset,
      bottom: chatItemRenderMode.sectionHeaderBottomInset,
      trailing: Theme.Layout.screenEdgeOpticalInset
    )
  }

  private var listTopContentMargin: CGFloat {
    chatItemRenderMode == .noLastMessage ? 0 : 2
  }

  private var listSectionSpacing: CGFloat {
    chatItemRenderMode.listSectionSpacing
  }

  private var defaultMinimumListRowHeight: CGFloat {
    // Chat rows own their explicit 44/52/72pt floors. Removing List's global
    // 44pt floor lets section labels stay compact without shrinking tap rows.
    1
  }

  private func rows(for sectionItems: [ChatListItemSnapshot]) -> some View {
    ForEach(sectionItems) { item in
      swipeEnabledRow(for: item)
        .listRowSeparator(.hidden, edges: .top)
        .listRowSeparator(
          chatItemRenderMode == .noLastMessage || item.id == sectionItems.last?.id
            ? .hidden
            : .visible,
          edges: .bottom
        )
        .listRowSeparatorTint(Color(.separator).opacity(0.55))
        // Keep spacing inside the link so its tap and context-menu source
        // cover the complete native List row rather than only its contents.
        .listRowInsets(EdgeInsets())
        // Let the iPad List draw its native selection background.
        .listRowBackground(selection == nil ? Color.clear : nil)
    }
  }

  private func baseRow(for item: ChatListItemSnapshot) -> some View {
    let link = NavigationLink(value: Destination.chat(peer: item.peer)) {
      ExperimentalChatListRow(
        item: item,
        layoutMode: chatItemRenderMode.chatListLayoutMode,
        showsPinnedIndicator: false,
        showsActivityTime: true,
        unreadBadgeStyle: unreadBadgeStyle,
        leadingInset: rowLeadingInset
      )
      .equatable()
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(rowContentInsets)
      .contentShape(.interaction, Rectangle())
    }
    return Group {
      if selection != nil {
        // ForEach identifies rows by Peer; iPad List selection is a Destination.
        link.tag(Destination.chat(peer: item.peer))
      } else {
        link
      }
    }
    .navigationLinkIndicatorVisibility(.hidden)
    .contentShape(.interaction, Rectangle())
    .contentShape(.contextMenuPreview, Capsule())
    .contextMenu {
      contextMenuActions(for: item)
    } preview: {
      ChatContextMenuPreview(
        peer: item.peer,
        contextSpaceID: item.spaceID,
        router: router,
        data: data,
        themeManager: themeManager,
        notificationSettings: notificationSettings,
        realtimeState: realtimeState,
        realtimeV2: realtimeV2,
        appDatabase: appDatabase
      )
    }
  }

  private enum InboxSection: Hashable {
    case pinned
    case inbox
  }

  private struct InboxListSection: Identifiable {
    let id: InboxSection
    let title: LocalizedStringResource
    let items: [ChatListItemSnapshot]
  }

  private var inboxSections: [InboxListSection] {
    var sections: [InboxListSection] = []
    if !items.isEmpty {
      sections.append(InboxListSection(
        id: .inbox,
        title: "Open Chats",
        items: items
      ))
    }
    return sections
  }

  private struct InboxRowLocation: Equatable {
    let peer: Peer
    let section: InboxSection
  }

  private var rowContentInsets: EdgeInsets {
    EdgeInsets(
      top: chatItemRenderMode.listVerticalInset,
      leading: rowLeadingInset,
      bottom: chatItemRenderMode.listVerticalInset,
      trailing: Theme.Layout.screenEdgeOpticalInset
    )
  }

  private var rowLeadingInset: CGFloat {
    switch chatItemRenderMode {
    case .noLastMessage:
      // Compact keeps its outer identity close to the shared optical line while
      // preserving a small leading gutter for the unread dot.
      max(0, Theme.Layout.screenEdgeOpticalInset - 4)
    case .oneLineLastMessage, .twoLineLastMessage, .large:
      Theme.Layout.screenEdgeOpticalInset
    }
  }

  @ViewBuilder
  private func contextMenuActions(for item: ChatListItemSnapshot) -> some View {
    if mode == .inbox {
      contextMenuReadUnreadButton(for: item)
      contextMenuPinButton(for: item)
      Divider()
      contextMenuCloseButton(for: item)
      contextMenuArchiveButton(for: item)
    } else if mode == .allChats {
      contextMenuOpenButton(for: item)
      contextMenuReadUnreadButton(for: item)
      contextMenuPinButton(for: item)
      Divider()
      contextMenuArchiveButton(for: item)
    } else if mode == .archived {
      contextMenuUnarchiveButton(for: item)
      contextMenuReadUnreadButton(for: item)
    }
  }

  private func contextMenuCloseButton(for item: ChatListItemSnapshot) -> some View {
    Button {
      performClose(peer: item.peer)
    } label: {
      Label("Close", systemImage: "xmark")
    }
  }

  private func contextMenuPinButton(for item: ChatListItemSnapshot) -> some View {
    Button {
      // Unlike a swipe action, the context menu owns no List cell that must
      // finish dismissing before the stable row can move.
      performPinUpdate(peer: item.peer, pinned: !item.isPinned)
    } label: {
      Label(
        item.isPinned ? "Unpin" : "Pin",
        systemImage: item.isPinned ? "pin.slash" : "pin"
      )
    }
  }

  private func contextMenuReadUnreadButton(for item: ChatListItemSnapshot) -> some View {
    Button {
      performReadUnreadUpdate(peer: item.peer, isUnread: item.isUnread)
    } label: {
      Label(
        item.isUnread ? "Mark as Read" : "Mark as Unread",
        systemImage: item.isUnread ? "checkmark.message" : "envelope.badge"
      )
    }
  }

  private func contextMenuOpenButton(for item: ChatListItemSnapshot) -> some View {
    Button {
      performOpen(item)
    } label: {
      Label("Open", systemImage: "tray.and.arrow.down")
      Text("Add to Open Chats")
    }
  }

  private func contextMenuArchiveButton(for item: ChatListItemSnapshot) -> some View {
    Button(role: .destructive) {
      requestArchive(item)
    } label: {
      Label("Archive", systemImage: "archivebox")
    }
  }

  private func contextMenuUnarchiveButton(for item: ChatListItemSnapshot) -> some View {
    Button {
      performUnarchive(item)
    } label: {
      Label("Unarchive", systemImage: "arrow.uturn.backward")
    }
  }

  @ViewBuilder
  private func swipeEnabledRow(for item: ChatListItemSnapshot) -> some View {
    let row = baseRow(for: item)

    if #available(iOS 27.0, *) {
      row
        .swipeActions(
          edge: .leading,
          allowsFullSwipe: mode == .allChats,
          content: {
            leadingSwipeActions(for: item)
          },
          onPresentationChanged: { isPresented in
            swipePresentationChanged(isPresented, peer: item.peer)
          }
        )
        .swipeActions(
          edge: .trailing,
          allowsFullSwipe: true,
          content: {
            trailingSwipeActions(for: item)
          },
          onPresentationChanged: { isPresented in
            swipePresentationChanged(isPresented, peer: item.peer)
          }
        )
    } else {
      row
        .swipeActions(edge: .leading, allowsFullSwipe: mode == .allChats) {
          leadingSwipeActions(for: item)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
          trailingSwipeActions(for: item)
        }
    }
  }

  @ViewBuilder
  private func leadingSwipeActions(for item: ChatListItemSnapshot) -> some View {
    readUnreadButton(for: item)
    if item.peer.asUserId() == nil {
      followButton(for: item)
    }
  }

  @ViewBuilder
  private func trailingSwipeActions(for item: ChatListItemSnapshot) -> some View {
    if mode == .inbox {
      closeButton(for: item)
    } else if mode == .allChats {
      openButton(for: item)
      archiveButton(for: item)
    } else if mode == .archived {
      unarchiveButton(for: item)
    }
    if mode == .inbox || mode == .allChats {
      pinButton(for: item)
    }
  }

  private func closeButton(for item: ChatListItemSnapshot) -> some View {
    Button {
      performClose(peer: item.peer)
    } label: {
      Label("Close", systemImage: "xmark")
    }
    .tint(Color(uiColor: .systemGray3))
  }

  private func performClose(peer: Peer) {
    Task {
      do {
        _ = try await InboxMembershipService.shared.close(peer: peer)
      } catch {
        Log.shared.error("Failed to update Inbox state", error: error)
        ToastManager.shared.showToast(
          "Could not close chat",
          type: .error,
          systemImage: "exclamationmark.triangle.fill"
        )
      }
    }
  }

  private func openButton(for item: ChatListItemSnapshot) -> some View {
    Button {
      performOpen(item)
    } label: {
      Label("Open", systemImage: "tray.and.arrow.down.fill")
    }
    .tint(.green)
  }

  private func performOpen(_ item: ChatListItemSnapshot) {
    Task {
      do {
        if item.isOpen {
          ToastManager.shared.showToast(
            "Already open",
            description: "This chat is already in Open Chats.",
            type: .info,
            systemImage: "bubble.left.fill"
          )
          return
        }
        let didPerform = try await InboxMembershipService.shared.open(peer: item.peer)
        guard didPerform else { return }
        ToastManager.shared.showToast(
          "Now in Open Chats",
          type: .success,
          systemImage: "bubble.left.fill"
        )
      } catch {
        Log.shared.error("Failed to update Inbox state", error: error)
        ToastManager.shared.showToast(
          "Could not open chat",
          type: .error,
          systemImage: "exclamationmark.triangle.fill"
        )
      }
    }
  }

  private func performArchive(_ item: ChatListItemSnapshot) {
    Task {
      do {
        let didPerform = try await homeActions.perform(peer: item.peer) {
          try await data.updateDialog(
            peerId: item.peer,
            archived: true,
            spaceId: item.spaceID,
            deleteEmptyThreadIfArchiving: false
          )
        }
        guard didPerform else { return }
        ToastManager.shared.showToast(
          "Archived",
          type: .success,
          systemImage: "archivebox.fill",
          action: {
            performUnarchive(item, showsSuccessToast: false)
          },
          actionTitle: "Undo"
        )
      } catch {
        Log.shared.error("Failed to archive chat", error: error)
        ToastManager.shared.showToast(
          "Could not archive chat",
          type: .error,
          systemImage: "exclamationmark.triangle.fill"
        )
      }
    }
  }

  private func archiveButton(for item: ChatListItemSnapshot) -> some View {
    Button {
      requestArchive(item)
    } label: {
      Label("Archive", systemImage: "archivebox.fill")
    }
    .tint(.red)
  }

  private func requestArchive(_ item: ChatListItemSnapshot) {
    pendingArchiveItem = item
  }

  private func pinButton(for item: ChatListItemSnapshot) -> some View {
    Button {
      requestPinUpdate(peer: item.peer, pinned: !item.isPinned)
    } label: {
      Label(
        item.isPinned ? "Unpin" : "Pin",
        systemImage: item.isPinned ? "pin.slash.fill" : "pin.fill"
      )
    }
    .tint(.indigo)
  }

  private func requestPinUpdate(peer: Peer, pinned: Bool) {
    if #available(iOS 27.0, *) {
      // The active List cell remains owned by the native swipe presentation.
      // Mutate only after its dismissal callback so SwiftUI can animate the
      // same stable row from its source position to its destination.
      homeActions.deferPinUpdate(peer: peer, pinned: pinned)
    } else {
      Task {
        // Older SwiftUI has no swipe-dismissal callback. Keep the compatibility
        // wait local to this structural action instead of delaying list updates.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        performPinUpdate(peer: peer, pinned: pinned)
      }
    }
  }

  private func swipePresentationChanged(_ isPresented: Bool, peer: Peer) {
    guard !isPresented,
          let pinned = homeActions.takeDeferredPinUpdate(peer: peer)
    else { return }

    Task { @MainActor in
      // Commit after SwiftUI has finished the dismissal transaction.
      await Task.yield()
      performPinUpdate(peer: peer, pinned: pinned)
    }
  }

  private func performPinUpdate(peer: Peer, pinned: Bool) {
    Task {
      do {
        _ = try await homeActions.perform(peer: peer) {
          _ = try await realtimeV2.send(.updateDialogOrder(
            peerId: peer,
            pinned: pinned
          ))
        }
      } catch {
        Log.shared.error("Failed to update pin state", error: error)
        ToastManager.shared.showToast(
          "Could not update pin",
          type: .error,
          systemImage: "exclamationmark.triangle.fill"
        )
      }
    }
  }

  private func readUnreadButton(for item: ChatListItemSnapshot) -> some View {
    Button {
      performReadUnreadUpdate(peer: item.peer, isUnread: item.isUnread)
    } label: {
      Label(
        item.isUnread ? "Read" : "Unread",
        systemImage: item.isUnread ? "checkmark.message.fill" : "envelope.badge.fill"
      )
    }
    .tint(.blue)
  }

  private func followButton(for item: ChatListItemSnapshot) -> some View {
    Button {
      performFollowUpdate(peer: item.peer, isFollowed: item.isFollowed)
    } label: {
      Label(
        item.isFollowed ? "Unfollow" : "Follow",
        systemImage: item.isFollowed ? "eye.slash.fill" : "eye.fill"
      )
    }
    .tint(.purple)
  }

  private func performFollowUpdate(peer: Peer, isFollowed: Bool) {
    Task {
      do {
        _ = try await realtimeV2.send(.updateDialogFollowMode(
          peerId: peer,
          selection: isFollowed ? .unfollowed : .following
        ))
        ToastManager.shared.showToast(
          isFollowed ? "Unfollowed" : "Following",
          description: isFollowed
            ? "Only mentions and replies can bring this chat back."
            : "New messages will appear in Open Chats.",
          type: .success,
          systemImage: isFollowed ? "eye.slash.fill" : "eye.fill"
        )
      } catch {
        Log.shared.error("Failed to update follow state", error: error)
        ToastManager.shared.showToast(
          "Could not update follow state",
          type: .error,
          systemImage: "exclamationmark.triangle.fill"
        )
      }
    }
  }

  private func performReadUnreadUpdate(peer: Peer, isUnread: Bool) {
    Task {
      do {
        _ = try await homeActions.perform(peer: peer) {
          if isUnread {
            _ = try await realtimeV2.send(.readMessages(peerId: peer))
          } else {
            _ = try await realtimeV2.send(.markAsUnread(peerId: peer))
          }
        }
      } catch {
        Log.shared.error("Failed to update read state", error: error)
        ToastManager.shared.showToast(
          "Could not update unread state",
          type: .error,
          systemImage: "exclamationmark.triangle.fill"
        )
      }
    }
  }

  private func unarchiveButton(for item: ChatListItemSnapshot) -> some View {
    Button {
      performUnarchive(item)
    } label: {
      Label("Unarchive", systemImage: "arrow.uturn.backward.circle.fill")
    }
    .tint(.blue)
  }

  private func performUnarchive(
    _ item: ChatListItemSnapshot,
    showsSuccessToast: Bool = true
  ) {
    Task {
      do {
        let didPerform = try await homeActions.perform(peer: item.peer) {
          try await data.updateDialog(
            peerId: item.peer,
            archived: false,
            spaceId: item.spaceID,
            deleteEmptyThreadIfArchiving: false
          )
        }
        guard didPerform else { return }
        if showsSuccessToast {
          ToastManager.shared.showToast(
            "Restored to All Chats",
            type: .success,
            systemImage: "arrow.uturn.backward.circle.fill"
          )
        }
      } catch {
        Log.shared.error("Failed to unarchive chat", error: error)
        ToastManager.shared.showToast(
          "Could not restore chat",
          type: .error,
          systemImage: "exclamationmark.triangle.fill"
        )
      }
    }
  }
}

private struct ExperimentalHomeFailureStateView: View {
  let message: String

  var body: some View {
    ContentUnavailableView {
      Label("Chats unavailable", systemImage: "exclamationmark.bubble")
    } description: {
      Text(message)
    }
  }
}

private struct ExperimentalPinnedChatSection<Rows: View>: View {
  @Binding var isExpanded: Bool
  let chatItemRenderMode: ExperimentalHomeChatItemRenderMode
  let headerInsets: EdgeInsets
  let rows: Rows

  init(
    isExpanded: Binding<Bool>,
    chatItemRenderMode: ExperimentalHomeChatItemRenderMode,
    headerInsets: EdgeInsets,
    @ViewBuilder rows: () -> Rows
  ) {
    _isExpanded = isExpanded
    self.chatItemRenderMode = chatItemRenderMode
    self.headerInsets = headerInsets
    self.rows = rows()
  }

  var body: some View {
    Section {
      ExperimentalPinnedChatSectionHeader(
        isExpanded: isExpanded,
        chatItemRenderMode: chatItemRenderMode,
        action: toggle
      )
        .listRowInsets(headerInsets)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)

      if isExpanded {
        rows
      }
    }
  }

  private func toggle() {
    isExpanded.toggle()
  }
}

private struct ExperimentalPinnedChatSectionHeader: View {
  let isExpanded: Bool
  let chatItemRenderMode: ExperimentalHomeChatItemRenderMode
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Text("Pinned")
          .frame(maxWidth: .infinity, alignment: .leading)
        if !isExpanded {
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .offset(x: 2)
            .transition(.opacity)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .modifier(ExperimentalChatSectionHeaderStyle(chatItemRenderMode: chatItemRenderMode))
    .accessibilityValue(accessibilityValue)
    .accessibilityHint(accessibilityHint)
  }

  private var accessibilityValue: LocalizedStringKey {
    isExpanded ? "Expanded" : "Collapsed"
  }

  private var accessibilityHint: LocalizedStringKey {
    isExpanded ? "Collapses pinned chats" : "Expands pinned chats"
  }
}

private struct ExperimentalChatSectionHeader: View {
  let title: LocalizedStringResource
  let chatItemRenderMode: ExperimentalHomeChatItemRenderMode

  var body: some View {
    Text(title)
      .modifier(ExperimentalChatSectionHeaderStyle(chatItemRenderMode: chatItemRenderMode))
  }
}

private struct ExperimentalChatDaySectionHeader: View {
  let day: Date
  let chatItemRenderMode: ExperimentalHomeChatItemRenderMode

  var body: some View {
    title
      .modifier(ExperimentalChatSectionHeaderStyle(chatItemRenderMode: chatItemRenderMode))
  }

  private var title: Text {
    let calendar = Calendar.autoupdatingCurrent
    if calendar.component(.year, from: day) == calendar.component(.year, from: Date()) {
      return Text(day, format: .dateTime.month(.abbreviated).day())
    }
    return Text(day, format: .dateTime.month(.abbreviated).day().year())
  }
}

private struct ExperimentalChatTimelineSectionHeader: View {
  let period: ChatListTimelinePeriod
  let chatItemRenderMode: ExperimentalHomeChatItemRenderMode

  @Environment(\.calendar) private var calendar

  var body: some View {
    title
      .modifier(ExperimentalChatSectionHeaderStyle(chatItemRenderMode: chatItemRenderMode))
  }

  private var title: Text {
    switch period {
    case let .day(day):
      if calendar.isDateInToday(day) {
        Text("Today")
      } else if calendar.isDateInYesterday(day) {
        Text("Yesterday")
      } else {
        Text(day, format: .dateTime.weekday(.wide).month(.abbreviated).day())
      }
    case let .month(year, month):
      if let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) {
        Text(date, format: .dateTime.month(.wide))
      } else {
        Text(verbatim: "\(month)")
      }
    case let .year(year):
      if let date = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) {
        Text(date, format: .dateTime.year())
      } else {
        Text(verbatim: "\(year)")
      }
    }
  }
}

private struct ExperimentalChatSectionHeaderStyle: ViewModifier {
  let chatItemRenderMode: ExperimentalHomeChatItemRenderMode
  @ScaledMetric(relativeTo: .subheadline) private var compactFontSize: CGFloat = 15
  @ScaledMetric(relativeTo: .headline) private var regularFontSize: CGFloat = 16

  func body(content: Content) -> some View {
    content
      .font(.system(size: fontSize, weight: .semibold))
      .foregroundStyle(.secondary)
      .textCase(nil)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityAddTraits(.isHeader)
  }

  private var fontSize: CGFloat {
    switch chatItemRenderMode {
    case .noLastMessage:
      compactFontSize
    case .oneLineLastMessage, .twoLineLastMessage, .large:
      regularFontSize
    }
  }
}

private extension ExperimentalHomeChatItemRenderMode {
  var chatListLayoutMode: ChatListLayoutMode {
    switch self {
    case .large:
      .large
    case .oneLineLastMessage, .twoLineLastMessage:
      .standard
    case .noLastMessage:
      .compact
    }
  }

  var listVerticalInset: CGFloat {
    switch self {
    case .noLastMessage:
      0
    case .oneLineLastMessage, .twoLineLastMessage:
      5
    case .large:
      2
    }
  }

  var sectionHeaderBottomInset: CGFloat {
    switch self {
    case .noLastMessage:
      3
    case .oneLineLastMessage, .twoLineLastMessage, .large:
      4
    }
  }

  var listSectionSpacing: CGFloat {
    switch self {
    case .noLastMessage:
      7
    case .oneLineLastMessage, .twoLineLastMessage:
      10
    case .large:
      12
    }
  }
}

private struct ExperimentalEmptyStateView: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(spacing: 10) {
      Text(title)
        .font(.title3)
        .fontWeight(.semibold)

      Text(subtitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct ExperimentalLoadingStateView: View {
  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Loading chats...")
        .font(.headline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct ExperimentalInlineLogoEmptyStateView: View {
  var body: some View {
    // Target-local copy of the macOS empty-page symbol; keep the asset sets synchronized.
    Image("InlineLogoSymbol")
      .resizable()
      .scaledToFit()
      .frame(width: 64, height: 64)
      .opacity(0.09)
      .accessibilityHidden(true)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Members Sheet

struct ExperimentalMembersSheetView: View {
  let spaceId: Int64

  @Environment(Router.self) private var router
  @EnvironmentStateObject private var viewModel: SpaceFullMembersViewModel
  @State private var didRunInitialFetch = false

  init(spaceId: Int64) {
    self.spaceId = spaceId
    _viewModel = EnvironmentStateObject { env in
      SpaceFullMembersViewModel(db: env.appDatabase, spaceId: spaceId)
    }
  }

  var body: some View {
    NavigationStack {
      List {
        ForEach(viewModel.filteredMembers) { member in
          ExperimentalMemberRow(
            member: member,
            onMessage: {
              router.dismissSheet()
              router.openPrimaryDestination(.chat(peer: .user(id: member.userInfo.user.id)))
            }
          )
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
        }
      }
      .listStyle(.plain)
      .navigationTitle("Members")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            Task {
              await viewModel.refetchMembers()
            }
          } label: {
            if viewModel.isLoading {
              ProgressView()
            } else {
              Image(systemName: "arrow.clockwise")
            }
          }
          .accessibilityLabel("Refresh")
        }
      }
    }
    .task {
      guard !didRunInitialFetch else { return }
      didRunInitialFetch = true
      await viewModel.refetchMembers()
    }
  }
}

private struct ExperimentalMemberRow: View {
  let member: FullMemberItem
  let onMessage: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  private var buttonFill: Color {
    colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.045)
  }

  private var borderColor: Color {
    colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.07)
  }

  var body: some View {
    HStack(spacing: 12) {
      UserAvatar(userInfo: member.userInfo, size: 34)

      Text(member.userInfo.user.displayName)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(.primary)
        .lineLimit(1)

      Spacer(minLength: 0)

      Button(action: onMessage) {
        Image(systemName: "bubble.left.and.bubble.right.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.primary)
          .frame(width: 34, height: 34)
          .background(buttonFill, in: Circle())
          .overlay(
            Circle().stroke(borderColor, lineWidth: 0.5)
          )
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Message")
    }
    .padding(.vertical, 6)
  }
}
