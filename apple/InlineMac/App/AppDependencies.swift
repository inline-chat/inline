import Auth
import Foundation
import GRDB
import InlineCLIInstaller
import InlineKit
import Logger
import Observation
import RealtimeV2
import SwiftUI
import os.signpost

@MainActor
public struct AppDependencies {
  var appBridge: AppBridge
  let auth = Auth.shared
  let viewModel = MainWindowViewModel()
  var overlay = OverlayManager()
  let cliInstaller = CLIInstallerController()
#if SPARKLE
  let updates = UpdateController()
#endif
  let navigation = NavigationModel.shared
  let transactions = Transactions.shared
  let realtime = Realtime.shared
  let realtimeV2 = Api.realtime
  let database = AppDatabase.shared
  let data = DataManager(database: AppDatabase.shared)
  let session = MainWindowSessionRefresher()
  let unreadCounts = UnreadCountsModel.shared
  let userSettings = INUserSettings.current
  let gridRuntime = GridRuntime.shared
  let commandBarCatalog = CommandBarCatalogService(database: AppDatabase.shared)
  let appUndo = AppUndoHistory()
  var grid: GridRoomService { gridRuntime.rooms }

  // Per window
  let nav: Nav = .main
  var nav2: Nav2? = nil
  var nav3: Nav3? = nil
  var nav3ChatOpenPreloader: Nav3ChatOpenPreloadBridge? = nil
  var forwardMessages: ForwardMessagesPresenter? = nil
  var keyMonitor: KeyMonitor?

  // Optional
  var rootData: RootData?
  var logOut: (() async -> Void) = {}

  init(appBridge: AppBridge = AppBridge()) {
    self.appBridge = appBridge
  }
}

extension View {
  @ViewBuilder
  func environment(dependencies deps: AppDependencies) -> some View {
    let result = environment(\.auth, deps.auth)
      .environmentObject(deps.viewModel)
      .environment(deps.overlay)
      .environmentObject(deps.navigation)
      .environmentObject(deps.nav)
      .environmentObject(deps.data)
      .environmentObject(deps.userSettings.notification)
      .environmentObject(Api.realtime.stateObject)
      .environment(\.transactions, deps.transactions)
      .environment(\.realtime, deps.realtime)
      .environment(\.realtimeV2, deps.realtimeV2)
      .appDatabase(deps.database)
      .environment(\.logOut, deps.logOut)
      .environment(\.keyMonitor, deps.keyMonitor)
      .environment(\.appBridge, deps.appBridge)
      .environment(\.dependencies, deps)
      .environment(deps.unreadCounts)
      .environment(deps.grid)
      .environment(deps.nav2)

#if SPARKLE
    let updateResult = result.environment(deps.updates)
#else
    let updateResult = result
#endif

    let themedResult = updateResult.modifier(AppThemeModifier())

    if let rootData = deps.rootData {
      themedResult.environmentObject(rootData)
    } else {
      themedResult
    }
  }

  @ViewBuilder
  func environment(dependencies deps: AppDependencies?) -> some View {
    if let deps {
      environment(dependencies: deps)
    } else {
      self
    }
  }
}

private struct AppThemeModifier: ViewModifier {
  @ObservedObject private var settings = AppSettings.shared

  func body(content: Content) -> some View {
    content.tint(themeTint)
  }

  private var themeTint: Color {
    _ = settings.themeRevision
    return Color(nsColor: Theme.accentColor)
  }
}

extension AppDependencies {
  func with(appBridge: AppBridge) -> AppDependencies {
    var deps = self
    deps.appBridge = appBridge
    return deps
  }

  func with(nav3: Nav3?) -> AppDependencies {
    var deps = self
    deps.nav3 = nav3
    return deps
  }

  func openChatInfo(peer: Peer) {
    if let nav2 {
      nav2.navigate(to: .chatInfo(peer: peer))
      return
    }

    if let nav3 {
      nav3.open(.chatInfo(peer: peer))
      return
    }

    nav.open(.chatInfo(peer: peer))
  }

  func openChatRoute(peer: Peer) {
    if let nav2 {
      nav2.navigate(to: .chat(peer: peer))
      return
    }

    if let nav3 {
      nav3.open(.chat(peer: peer))
      return
    }

    nav.open(.chat(peer: peer))
  }

  func openReplyThreadInPane(parentPeer: Peer, threadPeer: Peer) {
    guard nav3?.openReplyThread(parentPeer: parentPeer, threadPeer: threadPeer) == true else {
      openChatRoute(peer: threadPeer)
      return
    }

    guard AppSettings.shared.sidebarAsInbox else { return }

    // The projection can only render a reply beneath its semantic parent when
    // both dialogs are present in the sidebar source.
    SidebarState.shared.keepReplyThreadInSidebar(
      parentPeer: parentPeer,
      threadPeer: threadPeer
    )
  }

  /// User-initiated chat open. Nav3 uses the temporary preload path here.
  /// Route restoration/hydration should call `Nav3.open` directly so the first
  /// frame commits immediately and the chat view performs its normal load.
  func requestOpenChat(peer: Peer, targetMessageId: Int64? = nil) {
    if let nav2 {
      nav2.requestOpenChat(peer: peer, targetMessageId: targetMessageId, database: database)
      return
    }

    if let nav3 {
      if let nav3ChatOpenPreloader {
        nav3ChatOpenPreloader.openChat(
          peer: peer,
          targetMessageId: targetMessageId,
          nav: nav3,
          database: database
        )
      } else {
        nav3.open(.chat(peer: peer))
      }
      return
    }

    nav.open(.chat(peer: peer))
  }

  /// Opens a link whose chat component is the stable chat-table ID. A chat ID
  /// does not imply a thread: private chats must resolve to their user peer.
  func requestOpenChat(chatId: Int64, targetMessageId: Int64? = nil) async {
    guard let peer = await resolveChatLinkPeer(chatId: chatId, targetMessageId: targetMessageId) else {
      ToastCenter.shared.showError("Couldn’t open chat link")
      return
    }

    requestOpenChat(peer: peer, targetMessageId: targetMessageId)
  }

  /// Resolves the stable chat-table ID used by `/chat` links to the peer shape
  /// used by navigation, fetching missing chat/message state when possible.
  func resolveChatLinkPeer(chatId: Int64, targetMessageId: Int64? = nil) async -> Peer? {
    let peer: Peer

    do {
      if let chat = try await database.reader.read({ db in
        try Chat.fetchOne(db, id: chatId)
      }) {
        guard let resolvedPeer = chat.deepLinkPeer else {
          Log.shared.error("Private chat link is missing its user peer")
          return nil
        }
        peer = resolvedPeer
      } else {
        // `Peer.thread` encodes InputPeer.chat. At this boundary it means a
        // chat-table lookup, not that the resolved chat is necessarily a thread.
        let result = try await realtimeV2.send(.getChat(peer: .thread(id: chatId)))
        guard case let .getChat(response) = result, response.hasChat else {
          return nil
        }
        guard let resolvedPeer = Chat(from: response.chat).deepLinkPeer else {
          Log.shared.error("Private chat link response is missing its user peer")
          return nil
        }
        peer = resolvedPeer
      }
    } catch {
      Log.shared.error("Failed to resolve chat link", error: error)
      return nil
    }

    if let targetMessageId {
      await fetchMessageLinkTargetIfNeeded(
        peer: peer,
        chatId: chatId,
        messageId: targetMessageId
      )
    }

    return peer
  }

  private func fetchMessageLinkTargetIfNeeded(peer: Peer, chatId: Int64, messageId: Int64) async {
    do {
      let isCached = try await database.reader.read { db in
        try Message
          .filter(Message.Columns.chatId == chatId)
          .filter(Message.Columns.messageId == messageId)
          .fetchCount(db) > 0
      }
      guard !isCached else { return }
    } catch {
      Log.shared.error("Failed to check message-link cache", error: error)
    }

    do {
      _ = try await realtimeV2.send(.getMessages(peer: peer, messageIds: [messageId]))
    } catch {
      // Opening the resolved chat is still useful when the target message is
      // already available through another local projection or the app is offline.
      Log.shared.error("Failed to fetch message-link target", error: error)
    }
  }

  @MainActor
  func requestOpenChatInHome(peer: Peer) {
    if let nav2 {
      nav2.requestOpenChatInHome(peer: peer, database: database)
      return
    }

    if let nav3 {
      nav3.selectHome()
      requestOpenChat(peer: peer)
      return
    }

    nav.openHome()
    nav.open(.chat(peer: peer))
  }

  @MainActor
  func openSpaceContext(id spaceId: Int64, name: String, keeping peer: Peer?) {
    if let nav2 {
      nav2.openSpace(Space(id: spaceId, name: name, date: Date()))
      if let peer {
        nav2.requestOpenChat(peer: peer, database: database)
      }
      return
    }

    if let nav3 {
      nav3.selectSpace(spaceId)
      return
    }

    nav.openSpace(spaceId)
    if let peer {
      nav.open(.chat(peer: peer))
    }
  }

  @discardableResult
  func removeChatFromNavigation(peer: Peer) -> Bool {
    var didRemove = nav.removeChat(peer: peer)
    if nav2?.removeChat(peer: peer) == true {
      didRemove = true
    }
    if nav3?.removeChat(peer: peer) == true {
      didRemove = true
    }
    return didRemove
  }

  var pendingChatPeer: Peer? {
    nav2?.pendingChatPeer ?? nav3ChatOpenPreloader?.pendingPeer
  }

  var activeSpaceId: Int64? {
    nav2?.activeSpaceId ?? nav3?.selectedSpaceId
  }
}

@MainActor
@Observable
final class MainWindowSessionRefresher {
  private static let chatsRetryDelays: [Duration] = [.milliseconds(250), .seconds(1)]

  private(set) var isFetchingSidebarChats = false
  private(set) var hasFetchedSidebarChats = false

  @ObservationIgnored private var sidebarFetchCount = 0
  @ObservationIgnored private var didFetchInitialData = false
  @ObservationIgnored private var initialTask: Task<Void, Never>?
  @ObservationIgnored private var chatsTask: Task<Void, Never>?

  private func beginSidebarFetch() {
    sidebarFetchCount += 1
    isFetchingSidebarChats = true
  }

  private func endSidebarFetch() {
    sidebarFetchCount = max(0, sidebarFetchCount - 1)
    isFetchingSidebarChats = sidebarFetchCount > 0
  }

  func fetchInitialDataIfNeeded(dependencies: AppDependencies) {
    guard didFetchInitialData == false else { return }
    guard Auth.shared.getIsLoggedIn() else { return }

    didFetchInitialData = true
    initialTask?.cancel()

    let realtime = dependencies.realtimeV2
    let data = dependencies.data

    beginSidebarFetch()
    initialTask = Task { @MainActor [weak self] in
      defer {
        self?.endSidebarFetch()
        self?.initialTask = nil
      }

      do {
        try await realtime.send(.getMe())
        AppSettings.shared.resolveSidebarModeForCurrentAccount()
      } catch is CancellationError {
        return
      } catch {
        Log.shared.error("Error fetching getMe info", error: error)
      }

      do {
        try Task.checkCancellation()
        try await data.getSpaces()
      } catch is CancellationError {
        return
      } catch {
        Log.shared.error("Error fetching spaces", error: error)
      }

      self?.refetchChats(dependencies: dependencies)
    }
  }

  func refetchChats(dependencies: AppDependencies) {
    guard let accountID = Auth.shared.getCurrentUserId() else { return }
    guard chatsTask == nil else { return }

    let realtime = dependencies.realtimeV2
    beginSidebarFetch()
    chatsTask = Task { @MainActor [weak self] in
      defer {
        self?.endSidebarFetch()
        self?.chatsTask = nil
      }

      let maxAttempts = Self.chatsRetryDelays.count + 1
      for attempt in 1 ... maxAttempts {
        guard Auth.shared.getCurrentUserId() == accountID else { return }
        do {
          try Task.checkCancellation()
          try await realtime.send(.getChats())
          guard Auth.shared.getCurrentUserId() == accountID else { return }
          self?.hasFetchedSidebarChats = true
          return
        } catch is CancellationError {
          return
        } catch {
          Log.shared.error("Error refetching getChats (attempt \(attempt)/\(maxAttempts))", error: error)
          guard attempt < maxAttempts else { return }
          do {
            try await Task.sleep(for: Self.chatsRetryDelays[attempt - 1])
          } catch {
            return
          }
        }
      }
    }
  }

  func reset() {
    didFetchInitialData = false
    initialTask?.cancel()
    chatsTask?.cancel()
    initialTask = nil
    chatsTask = nil
    sidebarFetchCount = 0
    isFetchingSidebarChats = false
    hasFetchedSidebarChats = false
  }
}

@MainActor
@Observable
final class Nav3ChatOpenPreloadBridge {
  private(set) var pendingPeer: Peer?

  @ObservationIgnored private let signpostLog = OSLog(subsystem: "InlineMac", category: "PointsOfInterest")
  @ObservationIgnored private var pendingTask: Task<Void, Never>?
  @ObservationIgnored private var pendingTargetMessageId: Int64?
  @ObservationIgnored private var requestID: UUID?
  @ObservationIgnored private var payloads: [Peer: PreparedChatPayload] = [:]

  init() {}

  func openChat(
    peer: Peer,
    targetMessageId: Int64? = nil,
    nav: Nav3,
    database: AppDatabase
  ) {
    if pendingPeer == peer {
      guard pendingTargetMessageId != targetMessageId else { return }
    }
    if pendingPeer == nil, nav.currentRoute == .chat(peer: peer) {
      if let targetMessageId {
        scrollOpenChat(peer: peer, targetMessageId: targetMessageId, database: database)
      }
      return
    }

    pendingTask?.cancel()
    payloads.removeAll(keepingCapacity: true)

    let id = UUID()
    requestID = id
    pendingPeer = peer
    pendingTargetMessageId = targetMessageId
    os_signpost(
      .event,
      log: signpostLog,
      name: "ChatOpenRequest",
      "%{public}s",
      String(describing: peer)
    )
    nav.beginChatNavigationSignpost(peer: peer)

    let preloadSignpostID = OSSignpostID(log: signpostLog)
    os_signpost(
      .begin,
      log: signpostLog,
      name: "ChatOpenPreload",
      signpostID: preloadSignpostID,
      "%{public}s",
      String(describing: peer)
    )

    pendingTask = Task(priority: .userInitiated) { @MainActor [weak self] in
      guard let self else { return }

      do {
        let payload = try await ChatOpenPreloader.shared.prepare(
          peer: peer,
          targetMessageId: targetMessageId,
          database: database
        )
        guard self.requestID == id else {
          os_signpost(
            .end,
            log: self.signpostLog,
            name: "ChatOpenPreload",
            signpostID: preloadSignpostID,
            "%{public}s",
            "superseded"
          )
          return
        }
        self.payloads[peer] = payload
        self.clearPending(cancelTask: false)
        os_signpost(
          .event,
          log: self.signpostLog,
          name: "ChatOpenPreloadRouteCommit",
          "%{public}s",
          String(describing: peer)
        )
        os_signpost(
          .end,
          log: self.signpostLog,
          name: "ChatOpenPreload",
          signpostID: preloadSignpostID,
          "%{public}s",
          "success"
        )
        nav.open(.chat(peer: peer), tracksChatNavigation: false)
      } catch is CancellationError {
        guard self.requestID == id else {
          os_signpost(
            .end,
            log: self.signpostLog,
            name: "ChatOpenPreload",
            signpostID: preloadSignpostID,
            "%{public}s",
            "superseded"
          )
          return
        }
        self.clearPending(cancelTask: false)
        os_signpost(
          .end,
          log: self.signpostLog,
          name: "ChatOpenPreload",
          signpostID: preloadSignpostID,
          "%{public}s",
          "cancelled"
        )
      } catch {
        guard self.requestID == id else {
          os_signpost(
            .end,
            log: self.signpostLog,
            name: "ChatOpenPreload",
            signpostID: preloadSignpostID,
            "%{public}s",
            "superseded"
          )
          return
        }
        self.clearPending(cancelTask: false)
        os_signpost(
          .event,
          log: self.signpostLog,
          name: "ChatOpenPreloadRouteCommit",
          "%{public}s",
          String(describing: peer)
        )
        os_signpost(
          .end,
          log: self.signpostLog,
          name: "ChatOpenPreload",
          signpostID: preloadSignpostID,
          "%{public}s",
          "error"
        )
        nav.open(.chat(peer: peer), tracksChatNavigation: false)
      }
    }
  }

  func consumePreparedPayload(for peer: Peer) -> PreparedChatPayload? {
    guard let payload = payloads.removeValue(forKey: peer), payload.peer == peer else {
      return nil
    }
    return payload
  }

  func cancelPendingOpenIfNeeded(for route: Nav3Route) {
    guard let pendingPeer else { return }
    if route.selectedPeer != pendingPeer {
      clearPending()
    }
  }

  func cancelPendingOpen() {
    clearPending()
  }

  private func scrollOpenChat(peer: Peer, targetMessageId: Int64, database: AppDatabase) {
    Task { @MainActor in
      do {
        let chat = try await database.reader.read { db in
          try Chat.getByPeerId(db: db, peerId: peer)
        }
        guard let chat else { return }
        ChatsManager
          .get(for: peer, chatId: chat.id)
          .scrollTo(msgId: targetMessageId, reason: .search)
      } catch {
        Log.shared.error("Failed to resolve open chat for search scroll", error: error)
      }
    }
  }

  private func clearPending(cancelTask: Bool = true) {
    if cancelTask {
      pendingTask?.cancel()
    }
    pendingTask = nil
    pendingTargetMessageId = nil
    requestID = nil
    pendingPeer = nil
  }
}
