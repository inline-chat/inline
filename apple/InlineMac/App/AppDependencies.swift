import Auth
import Foundation
import InlineKit
import Logger
import Observation
import RealtimeV2
import SwiftUI
import os.signpost

@MainActor
public struct AppDependencies {
  let auth = Auth.shared
  let viewModel = MainWindowViewModel()
  var overlay = OverlayManager()
  let updateInstallState = UpdateInstallState()
  let navigation = NavigationModel.shared
  let transactions = Transactions.shared
  let realtime = Realtime.shared
  let realtimeV2 = Api.realtime
  let database = AppDatabase.shared
  let data = DataManager(database: AppDatabase.shared)
  let session = MainWindowSessionRefresher()
  let userSettings = INUserSettings.current

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
}

extension View {
  @ViewBuilder
  func environment(dependencies deps: AppDependencies) -> some View {
    let result = environment(\.auth, deps.auth)
      .environmentObject(deps.viewModel)
      .environmentObject(deps.overlay)
      .environmentObject(deps.updateInstallState)
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
      .environment(\.dependencies, deps)
      .environment(deps.nav2)

    if let rootData = deps.rootData {
      result.environmentObject(rootData)
    } else {
      result
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

extension AppDependencies {
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

  /// User-initiated chat open. Nav3 uses the temporary preload path here.
  /// Route restoration/hydration should call `Nav3.open` directly so the first
  /// frame commits immediately and the chat view performs its normal load.
  func requestOpenChat(peer: Peer) {
    if let nav2 {
      nav2.requestOpenChat(peer: peer, database: database)
      return
    }

    if let nav3 {
      if let nav3ChatOpenPreloader {
        nav3ChatOpenPreloader.openChat(peer: peer, nav: nav3, database: database)
      } else {
        nav3.open(.chat(peer: peer))
      }
      return
    }

    nav.open(.chat(peer: peer))
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
  private(set) var isFetchingSidebarChats = false

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
    guard Auth.shared.getIsLoggedIn() else { return }
    guard chatsTask == nil else { return }

    let realtime = dependencies.realtimeV2
    beginSidebarFetch()
    chatsTask = Task { @MainActor [weak self] in
      defer {
        self?.endSidebarFetch()
        self?.chatsTask = nil
      }

      do {
        try await realtime.send(.getChats())
      } catch is CancellationError {
        return
      } catch {
        Log.shared.error("Error refetching getChats", error: error)
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
  }
}

@MainActor
@Observable
final class Nav3ChatOpenPreloadBridge {
  private(set) var pendingPeer: Peer?

  @ObservationIgnored private let signpostLog = OSLog(subsystem: "InlineMac", category: "PointsOfInterest")
  @ObservationIgnored private var pendingTask: Task<Void, Never>?
  @ObservationIgnored private var requestID: UUID?
  @ObservationIgnored private var payloads: [Peer: PreparedChatPayload] = [:]

  init() {}

  func openChat(peer: Peer, nav: Nav3, database: AppDatabase) {
    if pendingPeer == peer {
      return
    }
    if pendingPeer == nil, nav.currentRoute == .chat(peer: peer) {
      return
    }

    pendingTask?.cancel()
    payloads.removeAll(keepingCapacity: true)

    let id = UUID()
    requestID = id
    pendingPeer = peer
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
        let payload = try await ChatOpenPreloader.shared.prepare(peer: peer, database: database)
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

  private func clearPending(cancelTask: Bool = true) {
    if cancelTask {
      pendingTask?.cancel()
    }
    pendingTask = nil
    requestID = nil
    pendingPeer = nil
  }
}
