import Foundation
import InlineKit
import Observation
import os.signpost

enum Nav3Route: Hashable, Codable {
  enum ChatInfoQuery: String, Hashable, Codable {
    case files
    case media
    case links
    case participants
  }

  case empty
  case spaces
  case chat(peer: Peer)
  case chatInfo(peer: Peer, query: ChatInfoQuery? = nil)
  case profile(userId: Int64)
  case createSpace
  case newChat(spaceId: Int64?)
  case inviteToSpace(spaceId: Int64?)
  case members(spaceId: Int64)
  case spaceSettings(spaceId: Int64)
  case spaceIntegrations(spaceId: Int64)
}

extension Nav3Route {
  var selectedPeer: Peer? {
    switch self {
    case let .chat(peer), let .chatInfo(peer, _):
      peer
    default:
      nil
    }
  }

  var selectedSpaceId: Int64? {
    switch self {
    case let .newChat(spaceId), let .inviteToSpace(spaceId):
      spaceId
    case let .members(spaceId), let .spaceSettings(spaceId), let .spaceIntegrations(spaceId):
      spaceId
    default:
      nil
    }
  }

}

struct Nav3RouteState: Hashable, RawRepresentable {
  var route: Nav3Route
  var selectedSpaceId: Int64?

  static let empty = Nav3RouteState(route: .empty)

  init(route: Nav3Route = .empty, selectedSpaceId: Int64? = nil) {
    self.route = route
    self.selectedSpaceId = selectedSpaceId
  }

  init(nav: Nav3) {
    self.init(route: nav.currentRoute, selectedSpaceId: nav.selectedSpaceId)
  }

  init?(rawValue: String) {
    guard !rawValue.isEmpty else {
      self = .empty
      return
    }
    guard let data = rawValue.data(using: .utf8) else {
      self = .empty
      return
    }

    if let payload = try? JSONDecoder().decode(Payload.self, from: data) {
      self = Self(route: payload.route, selectedSpaceId: payload.selectedSpaceId)
      return
    }

    if let route = try? JSONDecoder().decode(Nav3Route.self, from: data) {
      self = Self(route: route, selectedSpaceId: route.selectedSpaceId)
      return
    }

    self = .empty
  }

  var rawValue: String {
    guard route != .empty || selectedSpaceId != nil else { return "" }
    let payload = Payload(route: route, selectedSpaceId: selectedSpaceId)
    guard let data = try? JSONEncoder().encode(payload) else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
  }

  private struct Payload: Codable {
    var route: Nav3Route
    var selectedSpaceId: Int64?
  }
}

/// This nav class is per window
@Observable
class Nav3 {
  @ObservationIgnored private let navigationSignpostLog = OSLog(subsystem: "InlineMac", category: "PointsOfInterest")
  @ObservationIgnored private var activeChatNavigation: (peer: Peer, id: OSSignpostID)?
  @ObservationIgnored var onRouteChange: (() -> Void)?

  var history: [Nav3Route] = []
  var historyIndex: Int = -1
  var cmdKVisible = false
  var selectedSpaceId: Int64?

  var currentRoute: Nav3Route {
    guard history.indices.contains(historyIndex) else { return .empty }
    return history[historyIndex]
  }

  var canGoBack: Bool {
    historyIndex > 0
  }

  var canGoForward: Bool {
    historyIndex >= 0 && historyIndex < history.count - 1
  }

  /// Used for environment defaults and previews
  public static let `default` = Nav3()

  init(routeState: String = "", pendingRoute: Nav3Route? = nil) {
    restoreIfNeeded(from: routeState, pendingRoute: pendingRoute)
  }

  func open(_ route: Nav3Route, tracksChatNavigation: Bool = true) {
    var didChange = false
    if let spaceId = route.selectedSpaceId {
      didChange = selectedSpaceId != spaceId
      selectedSpaceId = spaceId
    }

    if currentRoute == route {
      if didChange {
        notifyRouteChange()
      }
      return
    }
    if tracksChatNavigation, case let .chat(peer) = route {
      beginChatNavigationSignpost(peer: peer)
    }
    if canGoForward {
      history.removeSubrange((historyIndex + 1)...)
    }
    history.append(route)
    historyIndex = history.count - 1

    if case let .chat(peer) = route {
      os_signpost(
        .event,
        log: navigationSignpostLog,
        name: "ChatRouteCommit",
        "%{public}s",
        String(describing: peer)
      )
    }

    notifyRouteChange()
  }

  func replace(_ route: Nav3Route) {
    guard history.indices.contains(historyIndex) else {
      open(route)
      return
    }
    guard history[historyIndex] != route else { return }
    history[historyIndex] = route
    notifyRouteChange()
  }

  func reset() {
    guard currentRoute != .empty || selectedSpaceId != nil || cmdKVisible else { return }
    history = []
    historyIndex = -1
    cmdKVisible = false
    selectedSpaceId = nil
    notifyRouteChange()
  }

  func selectHome() {
    guard selectedSpaceId != nil else { return }
    selectedSpaceId = nil
    notifyRouteChange()
  }

  func selectSpace(_ spaceId: Int64) {
    guard selectedSpaceId != spaceId else { return }
    selectedSpaceId = spaceId
    notifyRouteChange()
  }

  func goBack() {
    guard canGoBack else { return }
    historyIndex -= 1
    notifyRouteChange()
  }

  func goForward() {
    guard canGoForward else { return }
    historyIndex += 1
    notifyRouteChange()
  }

  func openCommandBar() {
    cmdKVisible = true
  }

  func closeCommandBar() {
    cmdKVisible = false
  }

  private func notifyRouteChange() {
    onRouteChange?()
  }

  func beginChatNavigationSignpost(peer: Peer) {
    if let activeChatNavigation {
      os_signpost(
        .end,
        log: navigationSignpostLog,
        name: "ChatNavigation",
        signpostID: activeChatNavigation.id,
        "%{public}s",
        "superseded"
      )
    }

    let signpostID = OSSignpostID(log: navigationSignpostLog)
    activeChatNavigation = (peer, signpostID)
    os_signpost(
      .begin,
      log: navigationSignpostLog,
      name: "ChatNavigation",
      signpostID: signpostID,
      "%{public}s",
      String(describing: peer)
    )
  }

  func endChatNavigationSignpost(peer: Peer, reason: String) {
    guard let activeChatNavigation, activeChatNavigation.peer == peer else { return }
    os_signpost(
      .end,
      log: navigationSignpostLog,
      name: "ChatNavigation",
      signpostID: activeChatNavigation.id,
      "%{public}s",
      reason
    )
    self.activeChatNavigation = nil
  }

  func restoreIfNeeded(from routeState: String, pendingRoute: Nav3Route? = nil) {
    guard currentRoute == .empty else { return }

    if let pendingRoute, pendingRoute != .empty {
      open(pendingRoute)
      return
    }

    guard let state = Self.decodeRouteState(routeState) else { return }
    selectedSpaceId = state.selectedSpaceId
    open(state.route)
  }

  func encodedRouteState() -> String? {
    Nav3RouteState(nav: self).rawValue
  }

  private static func decodeRouteState(_ routeState: String) -> Nav3RouteState? {
    guard let state = Nav3RouteState(rawValue: routeState) else { return nil }
    guard state.route != .empty || state.selectedSpaceId != nil else { return nil }
    return state
  }

}
