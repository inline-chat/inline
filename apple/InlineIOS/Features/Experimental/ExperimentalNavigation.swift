import Combine
import GRDB
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

  @Environment(Router.self) private var router
  @EnvironmentObject private var compactSpaceList: CompactSpaceList
  @EnvironmentObject private var data: DataManager
  @EnvironmentObject private var home: HomeViewModel
  @EnvironmentObject private var notificationHandler: NotificationHandler
  @EnvironmentObject private var chatsModel: ExperimentalSpaceChatsViewModel
  @Environment(\.realtimeV2) private var realtimeV2

  @AppStorage(ExperimentalHomePreferenceKeys.chatScope) private var homeChatScopeRaw: String = ExperimentalHomeChatScope.all.rawValue
  @AppStorage(ExperimentalHomePreferenceKeys.chatItemRenderMode) private var chatItemRenderModeRaw: String = ExperimentalHomeChatItemRenderMode.twoLineLastMessage.rawValue
  @AppStorage(ExperimentalHomePreferenceKeys.sortMode) private var sortModeRaw: String = ExperimentalHomeSortMode.recentActivity.rawValue
  @State private var hasLoadedHomeData = false
  @State private var isLoadingHomeData = false

  var body: some View {
    Group {
      switch initialTab {
      case .inbox:
        ExperimentalChatListView(
          items: inboxItems,
          mode: .inbox,
          emptyStyle: .inlineLogo,
          emptyTitle: "Inbox is clear",
          emptySubtitle: "Open a chat from All Chats to keep it here.",
          sectionHeader: nil,
          chatItemRenderMode: chatItemRenderMode,
          isLoading: isLoadingHomeData
        )
      case .allChats:
        ExperimentalChatListView(
          items: allChatItems,
          mode: .allChats,
          emptyStyle: .inlineLogo,
          emptyTitle: "No chats",
          emptySubtitle: "Start a new thread with the plus button.",
          sectionHeader: nil,
          chatItemRenderMode: chatItemRenderMode,
          isLoading: isLoadingHomeData
        )
      case .archived:
        ExperimentalChatListView(
          items: archivedItems,
          mode: .archived,
          emptyStyle: .text,
          emptyTitle: "No archived chats",
          emptySubtitle: "Archived chats will show up here.",
          sectionHeader: "Archived Chats",
          chatItemRenderMode: chatItemRenderMode,
          isLoading: isLoadingHomeData
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
    .navigationBarTitleDisplayMode(.inline)
    .navigationTitle("")
    .task {
      chatsModel.setSpaceId(nav.activeSpaceId)
      await loadHomeDataOnAppear()
    }
    .onChange(of: compactSpaceList.spaces) { _, _ in
      nav.pruneDialogFetchState(validSpaceIds: Set(compactSpaceList.spaces.map(\.id)))
      ensureActiveSpaceExists()
      chatsModel.setSpaceId(nav.activeSpaceId)
      Task { await refreshDialogsForCurrentSelection() }
    }
    .onChange(of: nav.activeSpaceId) { _, newValue in
      chatsModel.setSpaceId(newValue)
      Task { await reloadHomeData(forceDialogs: true) }
    }
  }

  private var homeChatScope: ExperimentalHomeChatScope {
    ExperimentalHomeChatScope(rawValue: homeChatScopeRaw) ?? .all
  }

  private var chatItemRenderMode: ExperimentalHomeChatItemRenderMode {
    ExperimentalHomeChatItemRenderMode(rawValue: chatItemRenderModeRaw) ?? .twoLineLastMessage
  }

  private var sortMode: ExperimentalHomeSortMode {
    ExperimentalHomeSortMode(rawValue: sortModeRaw) ?? .recentActivity
  }

  private var visibleChats: [HomeChatItem] { chatsModel.items }

  private var currentChats: [HomeChatItem] {
    let scopedChats: [HomeChatItem]

    if nav.activeSpaceId == nil {
      scopedChats = home.chats.filter { item in
        switch homeChatScope {
        case .all:
          true
        case .home:
          item.space == nil
        }
      }
    } else {
      scopedChats = visibleChats
    }

    switch sortMode {
    case .openedTime:
      return Self.sortByOpenedTime(scopedChats)
    case .recentActivity:
      return Self.sortByActivity(scopedChats)
    }
  }

  private var inboxItems: [HomeChatItem] {
    let items = nonArchivedItems.filter { item in
      item.dialog.open == true || item.dialog.pinned == true
    }

    return items.filter { $0.dialog.pinned == true }
      + items.filter { $0.dialog.pinned != true }
  }

  private var allChatItems: [HomeChatItem] {
    nonArchivedItems.filter { $0.dialog.open != true }
  }

  private var nonArchivedItems: [HomeChatItem] {
    currentChats.filter { $0.dialog.archived != true }
  }

  private var archivedItems: [HomeChatItem] {
    currentChats.filter { $0.dialog.archived == true }
  }

  private static func sortByActivity(_ items: [HomeChatItem]) -> [HomeChatItem] {
    items.sorted { lhs, rhs in
      let lhsDate = lhs.experimentalActivityDate
      let rhsDate = rhs.experimentalActivityDate
      if lhsDate == rhsDate {
        return lhs.id > rhs.id
      }
      return lhsDate > rhsDate
    }
  }

  private static func sortByOpenedTime(_ items: [HomeChatItem]) -> [HomeChatItem] {
    items.sorted { lhs, rhs in
      switch (lhs.dialog.openedDate, rhs.dialog.openedDate) {
      case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
        return lhsDate > rhsDate
      case (_?, nil):
        return true
      case (nil, _?):
        return false
      default:
        let lhsActivity = lhs.experimentalActivityDate
        let rhsActivity = rhs.experimentalActivityDate
        if lhsActivity == rhsActivity {
          return lhs.id > rhs.id
        }
        return lhsActivity > rhsActivity
      }
    }
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
    let shouldShowLoadingState = !hasLoadedHomeData || currentChats.isEmpty
    if shouldShowLoadingState {
      isLoadingHomeData = true
    }
    defer {
      hasLoadedHomeData = true
      isLoadingHomeData = false
    }

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

    chatsModel.setSpaceId(nav.activeSpaceId)
    await refreshDialogsForCurrentSelection(force: forceDialogs, availableSpaces: availableSpaces)
  }

  private func refreshDialogsForCurrentSelection(
    force: Bool = false,
    availableSpaces: [Space]? = nil
  ) async {
    if let spaceId = nav.activeSpaceId {
      await fetchDialogsIfNeeded(spaceId: spaceId, force: force)
    } else {
      // Home: show chats from all spaces, so ensure each space has at least one dialogs fetch.
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

@MainActor
final class ExperimentalSpaceChatsViewModel: ObservableObject {
  @Published private(set) var items: [HomeChatItem] = []

  private let db: AppDatabase
  private let log = Log.scoped("ExperimentalSpaceChatsViewModel")
  private var cancellable: AnyCancellable?
  private var activeSpaceId: Int64?

  init(db: AppDatabase) {
    self.db = db
  }

  func setSpaceId(_ spaceId: Int64?) {
    guard activeSpaceId != spaceId else { return }
    activeSpaceId = spaceId
    bind()
  }

  private func bind() {
    cancellable?.cancel()

    guard let spaceId = activeSpaceId else {
      items = []
      return
    }

    let spaceIdValue = spaceId
    items = []

    cancellable = ValueObservation
      .tracking { db in
        let space = try Space.fetchOne(db, id: spaceIdValue)

        let threads = try Dialog
          .spaceChatItemQuery()
          .filter(Column("spaceId") == spaceIdValue)
          .fetchAll(db)

        let contacts = try Dialog
          .spaceChatItemQueryForUser()
          .filter(
            sql: "dialog.peerUserId IN (SELECT userId FROM member WHERE spaceId = ?)",
            arguments: StatementArguments([spaceIdValue])
          )
          .fetchAll(db)

        return ExperimentalSpaceChatsSnapshot(
          space: space,
          threadItems: threads,
          contactItems: contacts
        )
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          guard let self else { return }
          if case let .failure(error) = completion {
            log.error("Failed to fetch experimental space chats for spaceId=\(spaceIdValue): \(error)")
          }
        },
        receiveValue: { [weak self] snapshot in
          guard let self else { return }

          let mapped = Self.mergeUnique(
            (snapshot.threadItems + snapshot.contactItems).map { item in
              HomeChatItem(
                dialog: item.dialog,
                user: item.userInfo,
                chat: item.chat,
                lastMessage: Self.embeddedMessage(for: item),
                space: snapshot.space
              )
            }
          )
          .filter { $0.chat != nil || $0.user != nil }

          items = HomeViewModel.sortChats(mapped)
        }
      )
  }

  private static func embeddedMessage(for item: SpaceChatItem) -> EmbeddedMessage? {
    guard let message = item.message else { return nil }
    return EmbeddedMessage(
      message: message,
      senderInfo: item.from,
      translations: item.translations,
      photoInfo: item.photoInfo,
      videoInfo: nil
    )
  }

  private static func mergeUnique(_ items: [HomeChatItem]) -> [HomeChatItem] {
    var seen = Set<Int64>()
    return items.filter { item in
      seen.insert(item.id).inserted
    }
  }

  private struct ExperimentalSpaceChatsSnapshot: Sendable {
    let space: Space?
    let threadItems: [SpaceChatItem]
    let contactItems: [SpaceChatItem]
  }
}

private enum ExperimentalChatListMode: Equatable {
  case inbox
  case allChats
  case archived
}

private enum ExperimentalChatSwipeEdge: Hashable {
  case leading
  case trailing
}

private struct ExperimentalChatSwipePresentation: Hashable {
  let peerId: Peer
  let edge: ExperimentalChatSwipeEdge
}

private struct ExperimentalChatListView: View {
  enum EmptyStyle {
    case text
    case inlineLogo
  }

  let items: [HomeChatItem]
  let mode: ExperimentalChatListMode
  let emptyStyle: EmptyStyle
  let emptyTitle: String
  let emptySubtitle: String
  let sectionHeader: String?
  let chatItemRenderMode: ExperimentalHomeChatItemRenderMode
  let isLoading: Bool

  @Environment(Router.self) private var router
  @EnvironmentObject private var data: DataManager
  @Environment(\.realtimeV2) private var realtimeV2
  @StateObject private var translationCoordinator = ChatListTranslationCoordinator()
  // TODO: Extract swipe reconciliation into an @Observable presentation model
  // and cover rapid inverse actions and failed mutations before shipping.
  @State private var presentedItems: [HomeChatItem]?
  @State private var pendingItemsAfterSwipe: [HomeChatItem]?
  @State private var activeSwipes = Set<ExperimentalChatSwipePresentation>()

  var body: some View {
    if isLoading && displayedItems.isEmpty {
      ExperimentalLoadingStateView()
    } else if displayedItems.isEmpty {
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
        } else if let sectionHeader {
          Section {
            rows(for: displayedItems)
          } header: {
            Text(sectionHeader)
              .textCase(nil)
          }
        } else {
          rows(for: displayedItems)
        }
      }
      .listStyle(.plain)
      .listSectionSpacing(
        chatItemRenderMode == .noLastMessage ? .custom(0) : .default
      )
      .onChange(of: items) { oldItems, newItems in
        reconcilePresentedItems(from: oldItems, to: newItems)
        translationCoordinator.process(
          items: newItems,
          currentPeers: currentPeers
        )
      }
      .onAppear {
        if presentedItems == nil {
          presentedItems = items
        }
        translationCoordinator.prime(items: items)
      }
      .onDisappear {
        translationCoordinator.cancel()
      }
    }
  }

  @ViewBuilder
  private var emptyContent: some View {
    switch emptyStyle {
    case .text:
      ExperimentalEmptyStateView(title: emptyTitle, subtitle: emptySubtitle)
    case .inlineLogo:
      ExperimentalInlineLogoEmptyStateView()
    }
  }

  private var displayedItems: [HomeChatItem] {
    presentedItems ?? items
  }

  private var sectionHeaderInsets: EdgeInsets {
    if chatItemRenderMode == .noLastMessage {
      return EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
    }

    return EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)
  }

  // TODO: Move day-section preparation into the shared chat snapshot and
  // schedule a midnight refresh so Today/Yesterday roll over without a data change.
  private var daySections: [ExperimentalChatDaySection] {
    let calendar = Calendar.autoupdatingCurrent
    var sections: [ExperimentalChatDaySection] = []

    for item in displayedItems {
      let day = calendar.startOfDay(for: item.experimentalActivityDate)
      if sections.last?.id == day {
        sections[sections.count - 1].items.append(item)
      } else {
        sections.append(ExperimentalChatDaySection(id: day, items: [item]))
      }
    }

    return sections
  }

  private var currentPeers: Set<Peer> {
    Set(router.selectedTabPath.compactMap { destination in
      if case let .chat(peer) = destination {
        return peer
      }
      return nil
    })
  }

  private func rows(for items: [HomeChatItem]) -> some View {
    ForEach(items) { item in
      swipeEnabledRow(for: item)
      .listRowSeparator(.hidden, edges: .top)
      .listRowSeparator(
        chatItemRenderMode == .noLastMessage || item.id == items.last?.id ? .hidden : .visible,
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

  private func baseRow(for item: HomeChatItem) -> some View {
    NavigationLink(value: Destination.chat(peer: item.peerId)) {
      rowContent(for: item)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
    .navigationLinkIndicatorVisibility(.hidden)
  }

  @ViewBuilder
  private func swipeEnabledRow(for item: HomeChatItem) -> some View {
    if #available(iOS 27.0, *) {
      baseRow(for: item)
        .swipeActions(
          edge: .leading,
          allowsFullSwipe: false,
          content: {
            readUnreadButton(for: item)
          },
          onPresentationChanged: { isPresented in
            setSwipePresented(
              isPresented,
              peerId: item.peerId,
              edge: .leading
            )
          }
        )
        .swipeActions(
          edge: .trailing,
          allowsFullSwipe: true,
          content: {
            trailingSwipeActions(for: item)
          },
          onPresentationChanged: { isPresented in
            setSwipePresented(
              isPresented,
              peerId: item.peerId,
              edge: .trailing
            )
          }
        )
    } else {
      baseRow(for: item)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
          readUnreadButton(for: item)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
          trailingSwipeActions(for: item)
        }
    }
  }

  @ViewBuilder
  private func trailingSwipeActions(for item: HomeChatItem) -> some View {
    if mode == .inbox {
      closeButton(for: item)
      pinButton(for: item)
    } else if mode == .allChats {
      openButton(for: item)
    }
  }

  private func setSwipePresented(
    _ isPresented: Bool,
    peerId: Peer,
    edge: ExperimentalChatSwipeEdge
  ) {
    let presentation = ExperimentalChatSwipePresentation(peerId: peerId, edge: edge)

    if isPresented {
      if activeSwipes.isEmpty {
        presentedItems = items
      }
      activeSwipes.insert(presentation)
      return
    }

    activeSwipes.remove(presentation)
    guard activeSwipes.isEmpty, let pendingItemsAfterSwipe else { return }

    self.pendingItemsAfterSwipe = nil
    withAnimation(.snappy(duration: 0.25, extraBounce: 0)) {
      presentedItems = pendingItemsAfterSwipe
    }
  }

  private func reconcilePresentedItems(
    from oldItems: [HomeChatItem],
    to newItems: [HomeChatItem]
  ) {
    guard !activeSwipes.isEmpty else {
      if #available(iOS 27.0, *) {
        withAnimation(.snappy(duration: 0.25, extraBounce: 0)) {
          presentedItems = newItems
        }
      } else {
        presentedItems = newItems
      }
      return
    }

    let currentItems = presentedItems ?? oldItems
    pendingItemsAfterSwipe = newItems

    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      presentedItems = mergeLatestContent(
        into: currentItems,
        from: newItems
      )
    }
  }

  private func mergeLatestContent(
    into currentItems: [HomeChatItem],
    from newItems: [HomeChatItem]
  ) -> [HomeChatItem] {
    let latestByID = Dictionary(uniqueKeysWithValues: newItems.map { ($0.id, $0) })
    let currentIDs = Set(currentItems.map(\.id))
    let retainedItems = currentItems.map { latestByID[$0.id] ?? $0 }
    let insertedItems = newItems.filter { !currentIDs.contains($0.id) }
    return retainedItems + insertedItems
  }

  @ViewBuilder
  private func closeButton(for item: HomeChatItem) -> some View {
    // TODO: Decide whether closing a pinned chat should also unpin it.
    // For the prototype, pinned chats stay in Inbox and expose Unpin instead.
    if item.dialog.open == true, item.dialog.pinned != true {
      Button(role: .destructive) {
        Task {
          do {
            _ = try await realtimeV2.send(
              .updateDialogOpen(peerId: item.peerId, open: false)
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
  }

  @ViewBuilder
  private func openButton(for item: HomeChatItem) -> some View {
    if item.dialog.open != true {
      Button(role: .destructive) {
        Task {
          do {
            _ = try await realtimeV2.send(
              .updateDialogOpen(peerId: item.peerId, open: true)
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

  @ViewBuilder
  private func pinButton(for item: HomeChatItem) -> some View {
    let isPinned = item.dialog.pinned ?? false

    Button {
      Task {
        do {
          try await data.updateDialog(
            peerId: item.peerId,
            pinned: !isPinned
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
        isPinned ? "Unpin" : "Pin",
        systemImage: isPinned ? "pin.slash.fill" : "pin.fill"
      )
    }
    .tint(.indigo)
  }

  @ViewBuilder
  private func readUnreadButton(for item: HomeChatItem) -> some View {
    let hasUnread = (item.dialog.unreadCount ?? 0) > 0 || item.dialog.unreadMark == true

    Button {
      Task {
        do {
          if hasUnread {
            UnreadManager.shared.readAll(item.peerId, chatId: item.chat?.id ?? 0)
          } else {
            _ = try await realtimeV2.send(.markAsUnread(peerId: item.peerId))
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
        hasUnread ? "Read" : "Unread",
        systemImage: hasUnread ? "checkmark.message.fill" : "envelope.badge.fill"
      )
    }
    .tint(.blue)
  }

  @ViewBuilder
  private func rowContent(for item: HomeChatItem) -> some View {
    if let user = item.displayUserInfo {
      ChatListItem(
        type: .user(user, chat: item.chat),
        dialog: item.dialog,
        lastMessage: item.lastMessage?.message,
        lastMessageSender: item.lastMessage?.senderInfo,
        embeddedLastMessage: item.lastMessage,
        showsPinnedIndicator: true,
        displayMode: chatItemRenderMode.chatListItemDisplayMode,
        rowStyle: chatItemRenderMode.chatListItemRowStyle
      )
    } else if let chat = item.chat {
      ChatListItem(
        type: .chat(chat, spaceName: nil),
        dialog: item.dialog,
        lastMessage: item.lastMessage?.message,
        lastMessageSender: item.lastMessage?.senderInfo,
        embeddedLastMessage: item.lastMessage,
        showsPinnedIndicator: true,
        displayMode: chatItemRenderMode.chatListItemDisplayMode,
        rowStyle: chatItemRenderMode.chatListItemRowStyle
      )
    } else {
      EmptyView()
    }
  }
}

private struct ExperimentalChatDaySection: Identifiable {
  let id: Date
  var items: [HomeChatItem]
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

private extension HomeChatItem {
  var experimentalActivityDate: Date {
    lastMessage?.message.date ?? chat?.date ?? .distantPast
  }
}

private extension ExperimentalHomeChatItemRenderMode {
  var chatListItemDisplayMode: ChatListItem.DisplayMode {
    switch self {
    case .large:
      .twoLineLastMessage
    case .oneLineLastMessage, .twoLineLastMessage:
      .oneLineLastMessage
    case .noLastMessage:
      .minimal
    }
  }

  var chatListItemRowStyle: ChatListItem.RowStyle {
    switch self {
    case .noLastMessage:
      .prototypeCompact
    case .oneLineLastMessage, .twoLineLastMessage:
      .prototypeWithPreview
    case .large:
      .prototypeLarge
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
