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
  private var failedHomeRefreshRequestIDs = Set<String>()

  private(set) var homeRefreshRevision = 0

  var activeSpaceId: Int64? {
    didSet {
      guard oldValue != activeSpaceId else { return }
      homeRefreshRevision += 1
      failedHomeRefreshRequestIDs.removeAll()
    }
  }

  var homeRefreshErrorDescription: String? {
    failedHomeRefreshRequestIDs.isEmpty ? nil : "Some chats could not be refreshed."
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
    succeeded: Bool,
    revision: Int,
    reportFailure: Bool = true
  ) {
    fetchingDialogSpaceIds.remove(spaceId)
    if succeeded {
      fetchedDialogSpaceIds.insert(spaceId)
    }
    recordHomeRefreshResult(
      requestID: "dialogs:\(spaceId)",
      succeeded: succeeded,
      revision: revision,
      reportFailure: reportFailure
    )
  }

  func recordHomeRefreshResult(
    requestID: String,
    succeeded: Bool,
    revision: Int,
    reportFailure: Bool = true
  ) {
    guard revision == homeRefreshRevision else { return }
    if succeeded {
      failedHomeRefreshRequestIDs.remove(requestID)
    } else if reportFailure {
      failedHomeRefreshRequestIDs.insert(requestID)
    }
  }

  func clearHomeRefreshFailures() {
    failedHomeRefreshRequestIDs.removeAll()
  }

  func pruneDialogFetchState(validSpaceIds: Set<Int64>) {
    fetchedDialogSpaceIds = fetchedDialogSpaceIds.filter { validSpaceIds.contains($0) }
    fetchingDialogSpaceIds = fetchingDialogSpaceIds.filter { validSpaceIds.contains($0) }
  }

  func resetHomeDataState() {
    didRunHomeBootstrap = false
    fetchedDialogSpaceIds.removeAll()
    fetchingDialogSpaceIds.removeAll()
    failedHomeRefreshRequestIDs.removeAll()
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
  var onRetryHome: () -> Void = {}

  var body: some View {
    content
  }

  @ViewBuilder
  private var content: some View {
    switch destination {
    case .chats:
      ExperimentalHomeView(nav: nav, initialTab: .inbox, onRetry: onRetryHome)
    case .archived:
      ExperimentalHomeView(nav: nav, initialTab: .archived, onRetry: onRetryHome)
    case .spaces:
      SpacesView()
    case let .space(id):
      SpaceView(spaceId: id)
    case let .chat(peer):
      ChatView(
        peer: peer,
        contextSpaceId: nav.activeSpaceId,
        autoCleanupUntitledEmptyThreadOnBack: true
      )
      .onAppear {
        ExperimentalHomeNavigationPerformance.completeChatOpen(peer: peer)
      }
    case let .externalChat(peer, contextSpaceID):
      ChatView(
        peer: peer,
        contextSpaceId: contextSpaceID,
        autoCleanupUntitledEmptyThreadOnBack: true
      )
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
        focusMessageID: messageID,
        autoCleanupUntitledEmptyThreadOnBack: true
      )
      .onAppear {
        ExperimentalHomeNavigationPerformance.completeChatOpen(peer: peer)
      }
    case let .chatInfo(chatItem):
      ChatInfoView(chatItem: chatItem)
    case let .spaceSettings(spaceId):
      SpaceSettingsView(spaceId: spaceId)
    case let .spaceIntegrations(spaceId):
      SpaceIntegrationsView(spaceId: spaceId)
    case let .integrationOptions(spaceId, provider):
      IntegrationOptionsView(spaceId: spaceId, provider: provider)
    case .createSpaceChat:
      CreateChatView(spaceId: nil)
    case let .createThread(spaceId):
      CreateChatView(spaceId: spaceId)
    case .createSpace:
      CreateSpaceView()
    }
  }
}

struct ExperimentalSheetView: View {
  let sheet: Sheet

  var body: some View {
    switch sheet {
    case .settings:
      NavigationStack {
        SettingsView()
      }
    case let .connectors(callbackURL):
      NavigationStack {
        ConnectorsView(initialOAuthCallbackURL: URL(string: callbackURL))
      }
    case .createSpace:
      CreateSpace()
    case .alphaSheet:
      AlphaSheet()
    case let .addMember(spaceId):
      InviteToSpaceView(spaceId: spaceId)
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
  @Bindable var nav: ExperimentalNavigationModel
  let initialTab: ExperimentalHomeTab
  var allChatsFilter: ChatListFilter = .all
  var onRetry: () -> Void = {}

  @EnvironmentObject private var homeListStore: ExperimentalHomeListStore

  @AppStorage(ExperimentalHomePreferenceKeys.chatItemRenderMode)
  private var chatItemRenderModeRaw = ExperimentalHomeChatItemRenderMode.twoLineLastMessage.rawValue

  @AppStorage(ExperimentalHomePreferenceKeys.unreadBadgeStyle)
  private var unreadBadgeStyleRawValue = ExperimentalHomeUnreadBadgeStyle.defaultValue.rawValue

  var body: some View {
    Group {
      switch initialTab {
      case .inbox:
        ExperimentalChatListView(
          items: homeListStore.state.presentation.inboxUnpinned,
          inboxPinnedItems: homeListStore.state.presentation.inboxPinned,
          daySections: [],
          mode: .inbox,
          emptyStyle: .inbox,
          emptyTitle: "Inbox is clear",
          emptySubtitle: "Open a chat from All Chats to keep it here.",
          chatItemRenderMode: chatItemRenderMode,
          unreadBadgeStyle: unreadBadgeStyle,
          isLoading: homeListStore.state.isLoading,
          status: homeStatus,
          onRetry: onRetry
        )
      case .allChats:
        ExperimentalChatListView(
          items: [],
          inboxPinnedItems: [],
          daySections: homeListStore.state.presentation.allChatSections,
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
          onRetry: onRetry
        )
      case .archived:
        ExperimentalChatListView(
          items: homeListStore.state.presentation.archived,
          inboxPinnedItems: [],
          daySections: [],
          mode: .archived,
          emptyStyle: .text,
          emptyTitle: "No archived chats",
          emptySubtitle: "Archived chats will show up here.",
          chatItemRenderMode: chatItemRenderMode,
          unreadBadgeStyle: unreadBadgeStyle,
          isLoading: homeListStore.state.isLoading,
          status: homeStatus,
          onRetry: onRetry
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
    .navigationBarTitleDisplayMode(.inline)
    .navigationTitle("")
  }

  private var chatItemRenderMode: ExperimentalHomeChatItemRenderMode {
    ExperimentalHomeChatItemRenderMode(rawValue: chatItemRenderModeRaw) ?? .twoLineLastMessage
  }

  private var unreadBadgeStyle: ExperimentalHomeUnreadBadgeStyle {
    ExperimentalHomeUnreadBadgeStyle(rawValue: unreadBadgeStyleRawValue) ?? .defaultValue
  }

  private var homeStatus: ExperimentalHomeStatus? {
    if homeListStore.state.errorDescription != nil {
      return .error("Chats could not be loaded from this device.")
    }
    if let message = nav.homeRefreshErrorDescription {
      return .error(message)
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
    case inbox
    case unreadFilter
  }

  let items: [ChatListItemSnapshot]
  let inboxPinnedItems: [ChatListItemSnapshot]
  let daySections: [ChatListDaySection]
  let mode: ExperimentalChatListMode
  let emptyStyle: EmptyStyle
  let emptyTitle: String
  let emptySubtitle: String
  let chatItemRenderMode: ExperimentalHomeChatItemRenderMode
  let unreadBadgeStyle: ExperimentalHomeUnreadBadgeStyle
  let isLoading: Bool
  let status: ExperimentalHomeStatus?
  let onRetry: () -> Void

  @EnvironmentObject private var data: DataManager
  @EnvironmentObject private var realtimeState: RealtimeState
  @Environment(Router.self) private var router
  @Environment(\.appDatabase) private var appDatabase
  @Environment(\.realtimeV2) private var realtimeV2
  @Environment(ExperimentalHomeActionCoordinator.self) private var homeActions

  var body: some View {
    Group {
      if isLoading && isEmpty {
        ExperimentalLoadingStateView()
      } else if isEmpty, case .error = status {
        ExperimentalHomeFailureStateView(onRetry: onRetry)
      } else if isEmpty {
        emptyContent
      } else {
        List {
          if mode == .allChats {
            ForEach(daySections) { section in
              Section {
                ExperimentalChatDaySectionHeader(day: section.id)
                  .listRowInsets(sectionHeaderInsets)
                  .listRowSeparator(.hidden)
                  .listRowBackground(Color.clear)

                rows(for: section.items)
              }
            }
          } else if mode == .inbox {
            ForEach(inboxSections) { section in
              Section {
                ExperimentalChatSectionHeader(title: section.title)
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
        .listStyle(.plain)
        .contentMargins(.top, listTopContentMargin, for: .scrollContent)
        .listSectionSpacing(.custom(listSectionSpacing))
        .environment(\.defaultMinListRowHeight, defaultMinimumListRowHeight)
        .animation(
          mode == .inbox ? .snappy(duration: 0.25, extraBounce: 0) : nil,
          value: animatedInboxRows
        )
      }
    }
  }

  /// A focused animation trigger for Inbox membership and ordering changes.
  /// Content updates keep the same identity sequence and do not animate.
  private var animatedInboxRows: [InboxRowLocation] {
    guard mode == .inbox else { return [] }
    return inboxPinnedItems.map { InboxRowLocation(peer: $0.peer, section: .pinned) }
      + items.map { InboxRowLocation(peer: $0.peer, section: .inbox) }
  }

  private var isEmpty: Bool {
    items.isEmpty && inboxPinnedItems.isEmpty && daySections.isEmpty
  }

  @ViewBuilder
  private var emptyContent: some View {
    switch emptyStyle {
    case .text:
      ExperimentalEmptyStateView(title: emptyTitle, subtitle: emptySubtitle)
    case .inlineLogo:
      ExperimentalInlineLogoEmptyStateView()
    case .inbox:
      ExperimentalInboxEmptyStateView(title: emptyTitle, subtitle: emptySubtitle)
    case .unreadFilter:
      ContentUnavailableView(
        emptyTitle,
        systemImage: "checkmark.message",
        description: Text(emptySubtitle)
      )
    }
  }

  private var sectionHeaderInsets: EdgeInsets {
    EdgeInsets(top: 1, leading: 20, bottom: 1, trailing: 20)
  }

  private var listTopContentMargin: CGFloat {
    chatItemRenderMode == .noLastMessage ? 0 : 2
  }

  private var listSectionSpacing: CGFloat {
    switch (mode, chatItemRenderMode) {
    case (.inbox, .noLastMessage):
      4
    case (.inbox, _):
      8
    case (.allChats, .noLastMessage):
      5
    case (.allChats, _):
      10
    case (.archived, _):
      8
    }
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
    }
  }

  private func baseRow(for item: ChatListItemSnapshot) -> some View {
    NavigationLink(value: Destination.chat(peer: item.peer)) {
      ExperimentalChatListRow(
        item: item,
        layoutMode: chatItemRenderMode.chatListLayoutMode,
        showsPinnedIndicator: false,
        showsActivityTime: true,
        unreadBadgeStyle: unreadBadgeStyle
      )
      .equatable()
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(rowContentInsets)
      .contentShape(.interaction, Rectangle())
    }
    .navigationLinkIndicatorVisibility(.hidden)
    .contentShape(.interaction, Rectangle())
    .contentShape(.contextMenuPreview, Capsule())
    .contextMenu {
      contextMenuActions(for: item)
    } preview: {
      ChatView(
        peer: item.peer,
        contextSpaceId: item.spaceID,
        preview: true
      )
      // SwiftUI presents context-menu previews in a separate hosting tree.
      // Re-inject every non-default dependency ChatView resolves before body.
      .environment(router)
      .environmentObject(data)
      .environmentObject(realtimeState)
      .environment(\.realtimeV2, realtimeV2)
      .appDatabase(appDatabase)
      .frame(idealWidth: 340, idealHeight: 480)
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
    sections.reserveCapacity(2)
    if !inboxPinnedItems.isEmpty {
      sections.append(InboxListSection(
        id: .pinned,
        title: "Pinned",
        items: inboxPinnedItems
      ))
    }
    if !items.isEmpty {
      sections.append(InboxListSection(
        id: .inbox,
        title: "Inbox",
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
      leading: 16,
      bottom: chatItemRenderMode.listVerticalInset,
      trailing: 20
    )
  }

  @ViewBuilder
  private func contextMenuActions(for item: ChatListItemSnapshot) -> some View {
    if mode == .inbox {
      contextMenuNavigateToChatButton(for: item)
      contextMenuReadUnreadButton(for: item)
      contextMenuPinButton(for: item)
      copyLinkButton(for: item)
      Divider()
      contextMenuCloseButton(for: item)
      contextMenuArchiveButton(for: item)
    } else if mode == .allChats {
      contextMenuOpenButton(for: item)
      contextMenuReadUnreadButton(for: item)
      copyLinkButton(for: item)
      Divider()
      contextMenuArchiveButton(for: item)
    } else if mode == .archived {
      contextMenuUnarchiveButton(for: item)
      contextMenuReadUnreadButton(for: item)
      copyLinkButton(for: item)
    }
  }

  private func contextMenuNavigateToChatButton(for item: ChatListItemSnapshot) -> some View {
    Button {
      ExperimentalHomeNavigationPerformance.beginChatOpen(
        peer: item.peer,
        source: "inbox_context_menu"
      )
      router.push(.chat(peer: item.peer))
    } label: {
      Label("Open", systemImage: "arrow.up.right")
    }
  }

  private func contextMenuCloseButton(for item: ChatListItemSnapshot) -> some View {
    Button {
      performClose(peer: item.peer)
    } label: {
      Label("Close", systemImage: "xmark.circle")
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

  @ViewBuilder
  private func contextMenuOpenButton(for item: ChatListItemSnapshot) -> some View {
    if !item.isOpen {
      Button {
        performOpen(item)
      } label: {
        Label("Open", systemImage: "tray.and.arrow.down")
      }
    }
  }

  private func contextMenuArchiveButton(for item: ChatListItemSnapshot) -> some View {
    Button(role: .destructive) {
      performArchive(item)
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
  private func copyLinkButton(for item: ChatListItemSnapshot) -> some View {
    if case let .thread(id) = item.peer,
       let url = InlineDeepLink.chat(id: id).webURL {
      Button {
        UIPasteboard.general.url = url
        ToastManager.shared.showToast(
          "Copied link",
          type: .success,
          systemImage: "link"
        )
      } label: {
        Label("Copy Link", systemImage: "link")
      }
    }
  }

  @ViewBuilder
  private func swipeEnabledRow(for item: ChatListItemSnapshot) -> some View {
    let row = baseRow(for: item)
      .swipeActions(edge: .leading, allowsFullSwipe: mode == .allChats) {
        leadingSwipeActions(for: item)
      }

    if #available(iOS 27.0, *) {
      row.swipeActions(
        edge: .trailing,
        allowsFullSwipe: true,
        content: {
          trailingSwipeActions(for: item)
        },
        onPresentationChanged: { isPresented in
          trailingSwipePresentationChanged(isPresented, peer: item.peer)
        }
      )
    } else {
      row.swipeActions(edge: .trailing, allowsFullSwipe: true) {
        trailingSwipeActions(for: item)
      }
    }
  }

  @ViewBuilder
  private func leadingSwipeActions(for item: ChatListItemSnapshot) -> some View {
    readUnreadButton(for: item)
  }

  @ViewBuilder
  private func trailingSwipeActions(for item: ChatListItemSnapshot) -> some View {
    if mode == .inbox {
      closeButton(for: item)
      pinButton(for: item)
    } else if mode == .allChats {
      openButton(for: item)
    } else if mode == .archived {
      unarchiveButton(for: item)
    }
  }

  private func closeButton(for item: ChatListItemSnapshot) -> some View {
    Button(role: .destructive) {
      performClose(peer: item.peer)
    } label: {
      Label("Close", systemImage: "xmark.circle.fill")
    }
    .tint(.gray)
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

  @ViewBuilder
  private func openButton(for item: ChatListItemSnapshot) -> some View {
    if !item.isOpen {
      Button {
        performOpen(item)
      } label: {
        Label("Open", systemImage: "tray.and.arrow.down.fill")
      }
      .tint(.green)
    }
  }

  private func performOpen(_ item: ChatListItemSnapshot) {
    Task {
      do {
        let didPerform = try await InboxMembershipService.shared.open(peer: item.peer)
        guard didPerform else { return }
        ToastManager.shared.showToast(
          "Opened in Inbox",
          type: .success,
          systemImage: "tray.full.fill"
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
            performUnarchive(item)
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

  private func trailingSwipePresentationChanged(_ isPresented: Bool, peer: Peer) {
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

  private func performUnarchive(_ item: ChatListItemSnapshot) {
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
        ToastManager.shared.showToast(
          "Restored to All Chats",
          type: .success,
          systemImage: "arrow.uturn.backward.circle.fill"
        )
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
  let onRetry: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("Chats unavailable", systemImage: "exclamationmark.bubble")
    } description: {
      Text("Your cached chats could not be shown. Try loading them again.")
    } actions: {
      Button("Retry", action: onRetry)
        .buttonStyle(.borderedProminent)
    }
  }
}

private struct ExperimentalChatSectionHeader: View {
  let title: LocalizedStringResource

  var body: some View {
    Text(title)
      .modifier(ExperimentalChatSectionHeaderStyle())
  }
}

private struct ExperimentalChatDaySectionHeader: View {
  let day: Date

  var body: some View {
    title
      .modifier(ExperimentalChatSectionHeaderStyle())
  }

  private var title: Text {
    let calendar = Calendar.autoupdatingCurrent
    if calendar.component(.year, from: day) == calendar.component(.year, from: Date()) {
      return Text(day, format: .dateTime.month(.abbreviated).day())
    }
    return Text(day, format: .dateTime.month(.abbreviated).day().year())
  }
}

private struct ExperimentalChatSectionHeaderStyle: ViewModifier {
  @ScaledMetric(relativeTo: .headline) private var fontSize: CGFloat = 16

  func body(content: Content) -> some View {
    content
      .font(.system(size: fontSize, weight: .semibold))
      .foregroundStyle(.secondary)
      .textCase(nil)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityAddTraits(.isHeader)
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
    .background(Color(.systemBackground))
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
    .background(Color(.systemBackground))
  }
}

private struct ExperimentalInboxEmptyStateView: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: "tray")
        .font(.title)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)

      Text(title)
        .font(.callout.weight(.semibold))

      Text(subtitle)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 240)
    }
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
  }
}

private struct ExperimentalInlineLogoEmptyStateView: View {
  var body: some View {
    Image("inlineIcon")
      .resizable()
      .scaledToFit()
      .frame(width: 64, height: 64)
      .opacity(0.09)
      .accessibilityHidden(true)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(.systemBackground))
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
              router.push(.chat(peer: .user(id: member.userInfo.user.id)))
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
