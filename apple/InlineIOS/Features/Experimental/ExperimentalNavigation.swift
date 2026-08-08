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
  var onRowVisibilityChange: (Peer, Bool) -> Void = { _, _ in }

  @EnvironmentObject private var homeListStore: ExperimentalHomeListStore

  @AppStorage(ExperimentalHomePreferenceKeys.chatItemRenderMode)
  private var chatItemRenderModeRaw = ExperimentalHomeChatItemRenderMode.twoLineLastMessage.rawValue

  var body: some View {
    Group {
      switch initialTab {
      case .inbox:
        ExperimentalChatListView(
          items: homeListStore.state.presentation.inbox,
          daySections: [],
          mode: .inbox,
          emptyStyle: .inbox,
          emptyTitle: "Inbox is clear",
          emptySubtitle: "Open a chat from All Chats to keep it here.",
          chatItemRenderMode: chatItemRenderMode,
          isLoading: homeListStore.state.isLoading,
          status: homeStatus,
          onRetry: onRetry,
          onRowVisibilityChange: onRowVisibilityChange
        )
      case .allChats:
        ExperimentalChatListView(
          items: [],
          daySections: homeListStore.state.presentation.allChatSections,
          mode: .allChats,
          emptyStyle: allChatsFilter == .unread ? .unreadFilter : .inlineLogo,
          emptyTitle: allChatsFilter == .unread ? "No unread chats" : "No chats",
          emptySubtitle: allChatsFilter == .unread
            ? "You’re caught up."
            : "Start a new thread with the plus button.",
          chatItemRenderMode: chatItemRenderMode,
          isLoading: homeListStore.state.isLoading,
          status: homeStatus,
          onRetry: onRetry,
          onRowVisibilityChange: onRowVisibilityChange
        )
      case .archived:
        ExperimentalChatListView(
          items: homeListStore.state.presentation.archived,
          daySections: [],
          mode: .archived,
          emptyStyle: .text,
          emptyTitle: "No archived chats",
          emptySubtitle: "Archived chats will show up here.",
          chatItemRenderMode: chatItemRenderMode,
          isLoading: homeListStore.state.isLoading,
          status: homeStatus,
          onRetry: onRetry,
          onRowVisibilityChange: onRowVisibilityChange
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
  let daySections: [ChatListDaySection]
  let mode: ExperimentalChatListMode
  let emptyStyle: EmptyStyle
  let emptyTitle: String
  let emptySubtitle: String
  let chatItemRenderMode: ExperimentalHomeChatItemRenderMode
  let isLoading: Bool
  let status: ExperimentalHomeStatus?
  let onRetry: () -> Void
  let onRowVisibilityChange: (Peer, Bool) -> Void

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
                rows(for: section.items)
              } header: {
                ExperimentalChatDaySectionHeader(day: section.id)
                  .listRowInsets(sectionHeaderInsets)
              }
            }
          } else {
            rows(for: items)
          }
        }
        .listStyle(.plain)
        .listSectionSpacing(
          chatItemRenderMode == .noLastMessage ? .custom(0) : .default
        )
        .animation(
          mode == .inbox ? .snappy(duration: 0.25, extraBounce: 0) : nil,
          value: animatedRowIDs
        )
      }
    }
  }

  /// A focused animation trigger for Inbox membership and ordering changes.
  /// Content updates keep the same identity sequence and do not animate.
  private var animatedRowIDs: [Peer] {
    mode == .inbox ? items.map(\.id) : []
  }

  private var isEmpty: Bool {
    items.isEmpty && daySections.isEmpty
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
    if chatItemRenderMode == .noLastMessage {
      return EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
    }
    return EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)
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
        // Keep spacing inside the link so its tap and context-menu source
        // cover the complete native List row rather than only its contents.
        .listRowInsets(EdgeInsets())
        .onAppear {
          onRowVisibilityChange(item.peer, true)
        }
        .onDisappear {
          onRowVisibilityChange(item.peer, false)
        }
    }
  }

  private func baseRow(for item: ChatListItemSnapshot) -> some View {
    NavigationLink(value: Destination.chat(peer: item.peer)) {
      ExperimentalChatListRow(
        item: item,
        layoutMode: chatItemRenderMode.chatListLayoutMode,
        showsPinnedIndicator: mode == .inbox,
        showsActivityTime: mode == .allChats
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

  private var rowContentInsets: EdgeInsets {
    EdgeInsets(
      top: chatItemRenderMode.listVerticalInset,
      leading: 12,
      bottom: chatItemRenderMode.listVerticalInset,
      trailing: 16
    )
  }

  @ViewBuilder
  private func contextMenuActions(for item: ChatListItemSnapshot) -> some View {
    if mode == .inbox {
      contextMenuPinButton(for: item)
      readUnreadButton(for: item)
      copyLinkButton(for: item)
      Divider()
      contextMenuCloseButton(for: item)
      archiveButton(for: item)
    } else if mode == .allChats {
      openButton(for: item)
      readUnreadButton(for: item)
      copyLinkButton(for: item)
      Divider()
      archiveButton(for: item)
    } else if mode == .archived {
      unarchiveButton(for: item)
      readUnreadButton(for: item)
      copyLinkButton(for: item)
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
        systemImage: item.isPinned ? "pin.slash.fill" : "pin.fill"
      )
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
    if mode == .allChats {
      archiveButton(for: item)
    }
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
      } label: {
        Label("Open", systemImage: "tray.and.arrow.down.fill")
      }
      .tint(.green)
    }
  }

  private func archiveButton(for item: ChatListItemSnapshot) -> some View {
    Button(role: .destructive) {
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
            description: "View it later in ••• → Archive.",
            type: .success,
            systemImage: "archivebox.fill"
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
    } label: {
      Label("Archive", systemImage: "archivebox.fill")
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
        _ = try await InboxMembershipService.shared.setPinned(peer: peer, pinned: pinned)
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
      Task {
        do {
          _ = try await homeActions.perform(peer: item.peer) {
            if item.isUnread {
              _ = try await realtimeV2.send(.readMessages(peerId: item.peer))
            } else {
              _ = try await realtimeV2.send(.markAsUnread(peerId: item.peer))
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
    } label: {
      Label(
        item.isUnread ? "Read" : "Unread",
        systemImage: item.isUnread ? "checkmark.message.fill" : "envelope.badge.fill"
      )
    }
    .tint(.blue)
  }

  private func unarchiveButton(for item: ChatListItemSnapshot) -> some View {
    Button {
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
    } label: {
      Label("Unarchive", systemImage: "arrow.uturn.backward.circle.fill")
    }
    .tint(.blue)
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

private struct ExperimentalChatDaySectionHeader: View {
  let day: Date

  var body: some View {
    title
      .font(.footnote.weight(.semibold))
      .foregroundStyle(.secondary)
      .textCase(nil)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var title: Text {
    let calendar = Calendar.autoupdatingCurrent
    if calendar.component(.year, from: day) == calendar.component(.year, from: Date()) {
      return Text(day, format: .dateTime.month(.abbreviated).day())
    }
    return Text(day, format: .dateTime.month(.abbreviated).day().year())
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
      8
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
  @Environment(\.colorScheme) private var colorScheme

  private var imageOpacity: Double {
    colorScheme == .dark ? 0.2 : 1.0
  }

  var body: some View {
    Image("inline-logo-bg")
      .resizable()
      .scaledToFit()
      .frame(maxWidth: 320, maxHeight: 320)
      .opacity(imageOpacity)
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
