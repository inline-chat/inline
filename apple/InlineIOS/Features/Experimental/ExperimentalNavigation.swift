import InlineKit
import InlineUI
import Invite
import Logger
import RealtimeV2
import SwiftUI

@MainActor
@Observable
final class ExperimentalNavigationModel {
  private static let activeSpaceDefaultsKey = "activeSpaceId"
  private var didRunHomeBootstrap = false
  private var fetchedDialogSpaceIds = Set<Int64>()
  private var fetchingDialogSpaceIds = Set<Int64>()

  var activeSpaceId: Int64? {
    didSet {
      saveActiveSpaceId(activeSpaceId)
    }
  }

  init() {
    activeSpaceId = Self.loadActiveSpaceId()
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

  func completeDialogsFetch(spaceId: Int64, succeeded: Bool) {
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
  }

  private static func loadActiveSpaceId() -> Int64? {
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

  private func saveActiveSpaceId(_ spaceId: Int64?) {
    let defaults = UserDefaults.standard
    if let spaceId {
      defaults.set(spaceId, forKey: Self.activeSpaceDefaultsKey)
    } else {
      defaults.removeObject(forKey: Self.activeSpaceDefaultsKey)
    }
  }
}

struct ExperimentalDestinationView: View {
  @Bindable var nav: ExperimentalNavigationModel
  let destination: Destination

  var body: some View {
    content
  }

  @ViewBuilder
  private var content: some View {
    switch destination {
    case .chats:
      ExperimentalHomeView(nav: nav, initialTab: .inbox)
    case .archived:
      ExperimentalHomeView(nav: nav, initialTab: .archived)
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

  @EnvironmentObject private var compactSpaceList: CompactSpaceList
  @EnvironmentObject private var data: DataManager
  @EnvironmentObject private var homeListStore: ExperimentalHomeListStore
  @EnvironmentObject private var notificationHandler: NotificationHandler
  @Environment(\.realtimeV2) private var realtimeV2

  @AppStorage(ExperimentalHomePreferenceKeys.chatItemRenderMode)
  private var chatItemRenderModeRaw = ExperimentalHomeChatItemRenderMode.twoLineLastMessage.rawValue

  var body: some View {
    Group {
      switch initialTab {
      case .inbox:
        ExperimentalChatListView(
          items: homeListStore.state.presentation.inbox,
          pinnedItems: [],
          daySections: [],
          mode: .inbox,
          emptyStyle: .inbox,
          emptyTitle: "Inbox is clear",
          emptySubtitle: "Open a chat from All Chats to keep it here.",
          sectionHeader: nil,
          chatItemRenderMode: chatItemRenderMode,
          isLoading: homeListStore.state.isLoading
        )
      case .allChats:
        ExperimentalChatListView(
          items: [],
          pinnedItems: homeListStore.state.presentation.closedPinned,
          daySections: homeListStore.state.presentation.allChatSections,
          mode: .allChats,
          emptyStyle: .inlineLogo,
          emptyTitle: "No chats",
          emptySubtitle: "Start a new thread with the plus button.",
          sectionHeader: nil,
          chatItemRenderMode: chatItemRenderMode,
          isLoading: homeListStore.state.isLoading
        )
      case .archived:
        ExperimentalChatListView(
          items: homeListStore.state.presentation.archived,
          pinnedItems: [],
          daySections: [],
          mode: .archived,
          emptyStyle: .text,
          emptyTitle: "No archived chats",
          emptySubtitle: "Archived chats will show up here.",
          sectionHeader: "Archived Chats",
          chatItemRenderMode: chatItemRenderMode,
          isLoading: homeListStore.state.isLoading
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
    .navigationBarTitleDisplayMode(.inline)
    .navigationTitle("")
    .task {
      await loadHomeDataOnAppear()
    }
    .onChange(of: compactSpaceList.spaces) { _, _ in
      nav.pruneDialogFetchState(validSpaceIds: Set(compactSpaceList.spaces.map(\.id)))
      ensureActiveSpaceExists()
      Task { await refreshDialogsForCurrentSelection() }
    }
    .onChange(of: nav.activeSpaceId) { _, _ in
      Task { await reloadHomeData(forceDialogs: true) }
    }
  }

  private var chatItemRenderMode: ExperimentalHomeChatItemRenderMode {
    ExperimentalHomeChatItemRenderMode(rawValue: chatItemRenderModeRaw) ?? .twoLineLastMessage
  }

  private func ensureActiveSpaceExists() {
    guard let activeSpaceId = nav.activeSpaceId else { return }
    guard !compactSpaceList.spaces.isEmpty else { return }
    if !compactSpaceList.spaces.contains(where: { $0.id == activeSpaceId }) {
      nav.activeSpaceId = nil
    }
  }

  private func loadHomeDataOnAppear() async {
    let shouldBootstrap = nav.consumeNeedsHomeBootstrap()
    await reloadHomeData(
      includeBootstrapData: shouldBootstrap,
      forceDialogs: nav.activeSpaceId != nil
    )
  }

  private func reloadHomeData(
    includeBootstrapData: Bool = false,
    forceDialogs: Bool = false
  ) async {
    var availableSpaces = compactSpaceList.spaces

    if includeBootstrapData {
      notificationHandler.setAuthenticated(value: true)

      do {
        _ = try await realtimeV2.send(.getMe())
      } catch {
        Log.shared.error("Failed to getMe", error: error)
      }

      do {
        _ = try await realtimeV2.send(.getChats())
      } catch {
        Log.shared.error("Failed to getChats", error: error)
      }

      do {
        availableSpaces = try await data.getSpaces()
        nav.pruneDialogFetchState(validSpaceIds: Set(availableSpaces.map(\.id)))
      } catch {
        Log.shared.error("Failed to getSpaces", error: error)
      }
    }

    await refreshDialogsForCurrentSelection(
      force: forceDialogs,
      availableSpaces: availableSpaces
    )
  }

  private func refreshDialogsForCurrentSelection(
    force: Bool = false,
    availableSpaces: [Space]? = nil
  ) async {
    if let spaceId = nav.activeSpaceId {
      await fetchDialogsIfNeeded(spaceId: spaceId, force: force)
    } else {
      // Cached rows remain interactive while remote reconciliation continues.
      for space in availableSpaces ?? compactSpaceList.spaces {
        await fetchDialogsIfNeeded(spaceId: space.id, force: force)
      }
    }
  }

  private func fetchDialogsIfNeeded(spaceId: Int64, force: Bool = false) async {
    guard nav.beginDialogsFetchIfNeeded(spaceId: spaceId, force: force) else { return }
    do {
      try await data.getDialogs(spaceId: spaceId)
      nav.completeDialogsFetch(spaceId: spaceId, succeeded: true)
    } catch {
      nav.completeDialogsFetch(spaceId: spaceId, succeeded: false)
      Log.shared.error("Failed to get dialogs", error: error)
    }
  }
}

private enum ExperimentalChatListMode: Equatable {
  case inbox
  case allChats
  case archived
}

private struct ExperimentalChatListView: View {
  enum EmptyStyle {
    case text
    case inlineLogo
    case inbox
  }

  let items: [ChatListItemSnapshot]
  let pinnedItems: [ChatListItemSnapshot]
  let daySections: [ChatListDaySection]
  let mode: ExperimentalChatListMode
  let emptyStyle: EmptyStyle
  let emptyTitle: String
  let emptySubtitle: String
  let sectionHeader: String?
  let chatItemRenderMode: ExperimentalHomeChatItemRenderMode
  let isLoading: Bool

  @EnvironmentObject private var data: DataManager
  @Environment(\.realtimeV2) private var realtimeV2

  var body: some View {
    if isLoading && isEmpty {
      ExperimentalLoadingStateView()
    } else if isEmpty {
      emptyContent
    } else {
      List {
        if mode == .allChats {
          if !pinnedItems.isEmpty {
            Section {
              rows(for: pinnedItems, showsPinnedIndicator: false)
            } header: {
              Text("Pinned")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
                .listRowInsets(sectionHeaderInsets)
            }
          }

          ForEach(daySections) { section in
            Section {
              rows(for: section.items)
            } header: {
              ExperimentalChatDaySectionHeader(day: section.id)
                .listRowInsets(sectionHeaderInsets)
            }
          }
        } else if let sectionHeader {
          Section {
            rows(for: items)
          } header: {
            Text(sectionHeader)
              .textCase(nil)
          }
        } else {
          rows(for: items)
        }
      }
      .listStyle(.plain)
      .listSectionSpacing(
        chatItemRenderMode == .noLastMessage ? .custom(0) : .default
      )
    }
  }

  private var isEmpty: Bool {
    items.isEmpty && pinnedItems.isEmpty && daySections.isEmpty
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
    }
  }

  private var sectionHeaderInsets: EdgeInsets {
    if chatItemRenderMode == .noLastMessage {
      return EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
    }
    return EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)
  }

  private func rows(
    for sectionItems: [ChatListItemSnapshot],
    showsPinnedIndicator: Bool = true
  ) -> some View {
    ForEach(sectionItems) { item in
      swipeEnabledRow(for: item, showsPinnedIndicator: showsPinnedIndicator)
        .listRowSeparator(.hidden, edges: .top)
        .listRowSeparator(
          chatItemRenderMode == .noLastMessage || item.id == sectionItems.last?.id
            ? .hidden
            : .visible,
          edges: .bottom
        )
        .listRowInsets(EdgeInsets(
          top: chatItemRenderMode.listVerticalInset,
          leading: 12,
          bottom: chatItemRenderMode.listVerticalInset,
          trailing: 16
        ))
    }
  }

  private func baseRow(
    for item: ChatListItemSnapshot,
    showsPinnedIndicator: Bool
  ) -> some View {
    NavigationLink(value: Destination.chat(peer: item.peer)) {
      ExperimentalChatListRow(
        item: item,
        layoutMode: chatItemRenderMode.chatListLayoutMode,
        showsPinnedIndicator: showsPinnedIndicator
      )
      .equatable()
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(.rect)
    }
    .navigationLinkIndicatorVisibility(.hidden)
  }

  private func swipeEnabledRow(
    for item: ChatListItemSnapshot,
    showsPinnedIndicator: Bool
  ) -> some View {
    baseRow(for: item, showsPinnedIndicator: showsPinnedIndicator)
      .swipeActions(edge: .leading, allowsFullSwipe: false) {
        readUnreadButton(for: item)
      }
      .swipeActions(edge: .trailing, allowsFullSwipe: true) {
        trailingSwipeActions(for: item)
      }
  }

  @ViewBuilder
  private func trailingSwipeActions(for item: ChatListItemSnapshot) -> some View {
    if mode == .inbox {
      closeButton(for: item)
      pinButton(for: item)
    } else if mode == .allChats {
      openButton(for: item)
      archiveButton(for: item)
    }
  }

  private func closeButton(for item: ChatListItemSnapshot) -> some View {
    Button(role: .destructive) {
      Task {
        do {
          _ = try await realtimeV2.send(
            .updateDialogOpen(peerId: item.peer, open: false)
          )
        } catch {
          Log.shared.error("Failed to update Inbox state", error: error)
          ToastManager.shared.showToast(
            "Could not close chat",
            type: .error,
            systemImage: "exclamationmark.triangle.fill"
          )
        }
      }
    } label: {
      Label("Close", systemImage: "xmark.circle.fill")
    }
    .tint(.gray)
  }

  @ViewBuilder
  private func openButton(for item: ChatListItemSnapshot) -> some View {
    if !item.isOpen {
      Button(role: .destructive) {
        Task {
          do {
            _ = try await realtimeV2.send(
              .updateDialogOpen(peerId: item.peer, open: true)
            )
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
          try await data.updateDialog(
            peerId: item.peer,
            archived: true,
            spaceId: item.spaceID
          )
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
      Task {
        do {
          try await data.updateDialog(
            peerId: item.peer,
            pinned: !item.isPinned,
            spaceId: item.spaceID
          )
        } catch {
          Log.shared.error("Failed to update pin state", error: error)
          ToastManager.shared.showToast(
            "Could not update pin",
            type: .error,
            systemImage: "exclamationmark.triangle.fill"
          )
        }
      }
    } label: {
      Label(
        item.isPinned ? "Unpin" : "Pin",
        systemImage: item.isPinned ? "pin.slash.fill" : "pin.fill"
      )
    }
    .tint(.indigo)
  }

  private func readUnreadButton(for item: ChatListItemSnapshot) -> some View {
    Button {
      Task {
        do {
          if item.isUnread {
            UnreadManager.shared.readAll(item.peer, chatId: item.chatID)
          } else {
            _ = try await realtimeV2.send(.markAsUnread(peerId: item.peer))
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
    if calendar.isDateInToday(day) {
      return Text("Today")
    }
    if calendar.isDateInYesterday(day) {
      return Text("Yesterday")
    }
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
        .font(.system(size: 30, weight: .regular))
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
