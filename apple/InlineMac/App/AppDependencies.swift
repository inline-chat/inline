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
private func tracedLaunchDependency<Value>(
  _ name: StaticString,
  _ make: () -> Value
) -> Value {
  let span = PerformanceTrace.begin(name, category: .launch)
  defer { span.end() }
  return make()
}

@MainActor
public struct AppDependencies {
  var appBridge: AppBridge
  let auth = tracedLaunchDependency("DependencyAuth") { Auth.shared }
  let viewModel = tracedLaunchDependency("DependencyMainWindowModel") { MainWindowViewModel() }
  var overlay = tracedLaunchDependency("DependencyOverlay") { OverlayManager() }
  let cliInstaller = tracedLaunchDependency("DependencyCLIInstaller") { CLIInstallerController() }
#if SPARKLE
  let updates = tracedLaunchDependency("DependencyUpdater") { UpdateController() }
#endif
  let navigation = tracedLaunchDependency("DependencyNavigation") { NavigationModel.shared }
  let transactions = tracedLaunchDependency("DependencyTransactions") { Transactions.shared }
  let realtime = tracedLaunchDependency("DependencyRealtimeLegacy") { Realtime.shared }
  let realtimeV2 = tracedLaunchDependency("DependencyRealtimeV2") { Api.realtime }
  let database = tracedLaunchDependency("DependencyDatabase") { AppDatabase.shared }
  let data = tracedLaunchDependency("DependencyDataManager") {
    DataManager(database: AppDatabase.shared)
  }
  let session = tracedLaunchDependency("DependencySessionRefresher") { MainWindowSessionRefresher() }
  let unreadCounts = tracedLaunchDependency("DependencyUnreadCounts") { UnreadCountsModel.shared }
  let userSettings = tracedLaunchDependency("DependencyUserSettings") { INUserSettings.current }
  let gridRuntime = tracedLaunchDependency("DependencyGridRuntime") { GridRuntime.shared }
  let commandBarCatalog = tracedLaunchDependency("DependencyCommandCatalog") {
    CommandBarCatalogService(database: AppDatabase.shared)
  }
  let appUndo = tracedLaunchDependency("DependencyUndo") { AppUndoHistory() }
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

  /// Direct navigation for a thread whose optimistic Chat/Dialog projection is
  /// already installed locally. Preserve the caller's Home/space context rather
  /// than selecting the thread's creation destination. Existing-chat opens keep
  /// using the preload path.
  @MainActor
  func openNewlyCreatedChatInCurrentContext(peer: Peer) {
    if let nav2 {
      nav2.navigate(to: .chat(peer: peer))
      return
    }

    if let nav3 {
      nav3ChatOpenPreloader?.cancelPendingOpen()
      nav3.open(.chat(peer: peer))
      return
    }

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
  private enum InitialRetryPhase {
    case currentUser
    case catalog
  }

  private static let chatsRetryDelays: [Duration] = [.milliseconds(250), .seconds(1)]
  private static let initialSelfRetryDelay: Duration = .seconds(5)

  private(set) var isFetchingSidebarChats = false
  private(set) var hasFetchedSidebarChats = false

  @ObservationIgnored private var sidebarFetchCount = 0
  @ObservationIgnored private var didFetchInitialData = false
  @ObservationIgnored private var didFetchCurrentUser = false
  @ObservationIgnored private var initialTask: Task<Void, Never>?
  @ObservationIgnored private var chatsTask: Task<Void, Never>?
  @ObservationIgnored private var initialRetryTask: Task<Void, Never>?
  @ObservationIgnored private var didUseCurrentUserSelfRetry = false
  @ObservationIgnored private var didUseCatalogSelfRetry = false
  @ObservationIgnored private var generation: UInt64 = 0

  private func canContinue(generation: UInt64, accountID: Int64) -> Bool {
    self.generation == generation
      && Auth.shared.getHasPendingAccountTransition() == false
      && Auth.shared.getCurrentUserId() == accountID
  }

  private func beginSidebarFetch() {
    sidebarFetchCount += 1
    isFetchingSidebarChats = true
  }

  private func endSidebarFetch(generation taskGeneration: UInt64) {
    guard generation == taskGeneration else { return }
    sidebarFetchCount = max(0, sidebarFetchCount - 1)
    isFetchingSidebarChats = sidebarFetchCount > 0
  }

  func fetchInitialDataIfNeeded(dependencies: AppDependencies) {
    guard didFetchInitialData == false else { return }
    guard initialTask == nil, chatsTask == nil, initialRetryTask == nil else { return }
    guard Auth.shared.getIsLoggedIn(), Auth.shared.getHasPendingAccountTransition() == false,
          let accountID = Auth.shared.getCurrentUserId()
    else { return }

    let realtime = dependencies.realtimeV2
    let taskGeneration = generation

    beginSidebarFetch()
    initialTask = Task { @MainActor [weak self] in
      defer {
        self?.endSidebarFetch(generation: taskGeneration)
        if self?.generation == taskGeneration {
          self?.initialTask = nil
        }
      }

      guard self?.canContinue(generation: taskGeneration, accountID: accountID) == true else {
        return
      }
      if self?.didFetchCurrentUser == false {
        do {
          let span = PerformanceTrace.begin("InitialGetMe", category: .launch)
          defer { span.end() }
          try await realtime.send(.getMe())
          guard self?.canContinue(generation: taskGeneration, accountID: accountID) == true else {
            return
          }
          AppSettings.shared.resolveSidebarModeForCurrentAccount()
          self?.didFetchCurrentUser = true
        } catch is CancellationError {
          return
        } catch {
          Log.shared.error("Error fetching getMe info", error: error)
          self?.scheduleInitialRetry(
            dependencies: dependencies,
            generation: taskGeneration,
            accountID: accountID,
            phase: .currentUser
          )
          return
        }
      }

      guard self?.canContinue(generation: taskGeneration, accountID: accountID) == true else {
        return
      }
      if self?.didFetchCurrentUser == true, self?.hasFetchedSidebarChats == true {
        self?.didFetchInitialData = true
        return
      }
      self?.refetchChats(dependencies: dependencies)
    }
  }

  func refetchChats(dependencies: AppDependencies) {
    guard Auth.shared.getHasPendingAccountTransition() == false,
          let accountID = Auth.shared.getCurrentUserId()
    else { return }
    guard chatsTask == nil else { return }

    let realtime = dependencies.realtimeV2
    let taskGeneration = generation
    beginSidebarFetch()
    chatsTask = Task { @MainActor [weak self] in
      defer {
        self?.endSidebarFetch(generation: taskGeneration)
        if self?.generation == taskGeneration {
          self?.chatsTask = nil
        }
      }

      let maxAttempts = Self.chatsRetryDelays.count + 1
      for attempt in 1 ... maxAttempts {
        guard self?.canContinue(generation: taskGeneration, accountID: accountID) == true else {
          return
        }
        do {
          let span = PerformanceTrace.begin("InitialGetChats", category: .launch)
          defer { span.end("attempt=\(attempt)") }
          try Task.checkCancellation()
          let expectedUserState = try await GRDBSyncStorage(db: dependencies.database)
            .getBucketState(for: .user)
          try await realtime.send(
            GetChatsTransaction(expectedUserBucketState: expectedUserState)
          )
          guard self?.canContinue(generation: taskGeneration, accountID: accountID) == true else {
            return
          }
          if self?.didFetchCurrentUser == true {
            self?.didFetchInitialData = true
          }
          self?.hasFetchedSidebarChats = true
          return
        } catch is CancellationError {
          return
        } catch {
          Log.shared.error("Error refetching getChats (attempt \(attempt)/\(maxAttempts))", error: error)
          guard attempt < maxAttempts else {
            self?.scheduleInitialRetry(
              dependencies: dependencies,
              generation: taskGeneration,
              accountID: accountID,
              phase: .catalog
            )
            return
          }
          do {
            try await Task.sleep(for: Self.chatsRetryDelays[attempt - 1])
          } catch {
            return
          }
        }
      }
    }
  }

  private func scheduleInitialRetry(
    dependencies: AppDependencies,
    generation taskGeneration: UInt64,
    accountID: Int64,
    phase: InitialRetryPhase
  ) {
    guard initialRetryTask == nil,
          canContinue(generation: taskGeneration, accountID: accountID)
    else { return }

    switch phase {
    case .currentUser:
      guard didUseCurrentUserSelfRetry == false else { return }
      didUseCurrentUserSelfRetry = true
    case .catalog:
      guard didUseCatalogSelfRetry == false else { return }
      didUseCatalogSelfRetry = true
    }

    beginSidebarFetch()
    initialRetryTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: Self.initialSelfRetryDelay)
      } catch {
        self?.finishInitialRetryWait(generation: taskGeneration)
        return
      }

      guard let self else { return }
      self.finishInitialRetryWait(generation: taskGeneration)
      guard self.canContinue(generation: taskGeneration, accountID: accountID) else { return }
      self.fetchInitialDataIfNeeded(dependencies: dependencies)
    }
  }

  private func finishInitialRetryWait(generation taskGeneration: UInt64) {
    guard generation == taskGeneration else { return }
    initialRetryTask = nil
    endSidebarFetch(generation: taskGeneration)
  }

  func reset() {
    generation &+= 1
    didFetchInitialData = false
    didFetchCurrentUser = false
    didUseCurrentUserSelfRetry = false
    didUseCatalogSelfRetry = false
    initialTask?.cancel()
    chatsTask?.cancel()
    initialRetryTask?.cancel()
    initialTask = nil
    chatsTask = nil
    initialRetryTask = nil
    sidebarFetchCount = 0
    isFetchingSidebarChats = false
    hasFetchedSidebarChats = false
  }

  func resetAndWait() async {
    let pendingInitialTask = initialTask
    let pendingChatsTask = chatsTask
    let pendingRetryTask = initialRetryTask
    reset()
    await pendingInitialTask?.value
    await pendingChatsTask?.value
    await pendingRetryTask?.value
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
        guard self.requestID == id, Auth.shared.getHasPendingAccountTransition() == false else {
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
        guard self.requestID == id, Auth.shared.getHasPendingAccountTransition() == false else {
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
        guard self.requestID == id, !Task.isCancelled, Auth.shared.getHasPendingAccountTransition() == false else {
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
        if targetMessageId != nil {
          ToastCenter.shared.showError("Could not load that message")
        }
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

  func cancelPendingOpenAndWait() async {
    let task = pendingTask
    clearPending()
    await task?.value
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
