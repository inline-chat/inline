import Combine
import Foundation
import GRDB
import InlineKit
import Logger
import Observation
import os.signpost

enum Nav2Route: Equatable, Hashable, Codable {
  case empty
  case spaces
  case chat(peer: Peer)
  case chatInfo(peer: Peer)
  case profile(userId: Int64)
  case createSpace
  case newChat
  case inviteToSpace
  case members(spaceId: Int64)
  case spaceIntegrations(spaceId: Int64)
}

enum TabId: Hashable, Codable {
  case home
  case space(id: Int64, name: String)
  // case chat(Int64, spaceId: Int64)

  static func == (lhs: TabId, rhs: TabId) -> Bool {
    switch (lhs, rhs) {
      case (.home, .home):
        true
      case let (.space(id: leftId, name: _), .space(id: rightId, name: _)):
        leftId == rightId
      default:
        false
    }
  }

  func hash(into hasher: inout Hasher) {
    switch self {
      case .home:
        hasher.combine(0)
      case let .space(id: id, name: _):
        hasher.combine(1)
        hasher.combine(id)
    }
  }

  var spaceId: Int64? {
    switch self {
      case let .space(id, _):
        id
      default:
        nil
    }
  }

  var tabTitle: String? {
    switch self {
      case let .space(_, name):
        name
      case .home:
        "Home"
    }
  }
}

struct Nav2Entry: Codable {
  var route: Nav2Route
  var tab: TabId
  var isImplicit: Bool

  init(route: Nav2Route, tab: TabId, isImplicit: Bool = false) {
    self.route = route
    self.tab = tab
    self.isImplicit = isImplicit
  }

  private enum CodingKeys: String, CodingKey {
    case route
    case tab
    case isImplicit
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    route = try container.decode(Nav2Route.self, forKey: .route)
    tab = try container.decode(TabId.self, forKey: .tab)
    isImplicit = try container.decodeIfPresent(Bool.self, forKey: .isImplicit) ?? false
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(route, forKey: .route)
    try container.encode(tab, forKey: .tab)
    try container.encode(isImplicit, forKey: .isImplicit)
  }
}

/// Manages navigation per window
@Observable class Nav2 {
  @ObservationIgnored private let log = Log.scoped("Nav2", enableTracing: false)
  @ObservationIgnored private var saveStateTask: Task<Void, Never>?
  @ObservationIgnored private let navigationSignpostLog = OSLog(subsystem: "InlineMac", category: "Navigation")
  @ObservationIgnored private var activeChatNavigation: (peer: Peer, id: OSSignpostID)?
  @ObservationIgnored private var pendingChatOpenTask: Task<Void, Never>?
  @ObservationIgnored private var pendingChatOpenRequestID: UUID?
  @ObservationIgnored private var preparedChatPayloads: [Peer: PreparedChatPayload] = [:]

  // MARK: - State

  var tabs: [TabId] = [.home]
  var pendingChatPeer: Peer?

  var activeTabIndex: Int = 0

  /// Last opened route per tab so we can restore when switching.
  var lastRoutes: [TabId: Nav2Route] = [:]

  /// History of navigation entries, current entry is last item in the history array
  var history: [Nav2Entry] = []

  var forwardHistory: [Nav2Entry] = []

  var activeSpaceId: Int64? {
    if let last = history.last, tabs.contains(last.tab) {
      return last.tab.spaceId
    }
    return activeTab.spaceId
  }

  var canGoBack: Bool {
    history.count > 1
  }

  var canGoForward: Bool {
    !forwardHistory.isEmpty
  }

  var activeTab: TabId {
    if tabs.indices.contains(activeTabIndex) {
      return tabs[activeTabIndex]
    }
    return tabs.first ?? .home
  }

  var currentRoute: Nav2Route {
    if let last = history.last, tabs.contains(last.tab) {
      return last.route
    }
    return .empty
  }

  func consumePreparedChatPayload(for peer: Peer) -> PreparedChatPayload? {
    guard let payload = preparedChatPayloads.removeValue(forKey: peer) else { return nil }
    guard payload.peer == peer else { return nil }
    return payload
  }

  // MARK: - Methods

  func navigate(to route: Nav2Route) {
    clearPendingChatOpenState()
    log.trace("Navigating to \(route)")
    if case let .chat(peer) = route {
      // PERF MARK: begin chat navigation signpost (remove when done).
      beginChatNavigationSignpost(peer: peer)
    }
    lastRoutes[activeTab] = route
    let didRecord = recordNavigation(route: route, tab: activeTab, isImplicit: false, replaceImplicit: true)
    if !didRecord, case let .chat(peer) = route {
      // No route transition means no consumer will read this payload.
      preparedChatPayloads.removeValue(forKey: peer)
    }
    forwardHistory.removeAll()
  }

  @MainActor
  func requestOpenChat(peer: Peer, database: AppDatabase = .shared) {
    if pendingChatPeer == peer {
      return
    }
    if case let .chat(currentPeer) = currentRoute, pendingChatPeer == nil, currentPeer == peer {
      return
    }

    pendingChatOpenTask?.cancel()
    preparedChatPayloads.removeValue(forKey: peer)

    let requestID = UUID()
    let requestTab = activeTab
    pendingChatOpenRequestID = requestID
    pendingChatPeer = peer

    pendingChatOpenTask = Task(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      do {
        let payload = try await ChatOpenPreloader.shared.prepare(peer: peer, database: database)
        await MainActor.run {
          guard self.pendingChatOpenRequestID == requestID else { return }
          guard self.activeTab == requestTab else {
            self.clearPendingChatOpenState(cancelTask: false)
            return
          }

          self.preparedChatPayloads[peer] = payload
          self.clearPendingChatOpenState(cancelTask: false)
          self.navigate(to: .chat(peer: peer))
        }
      } catch is CancellationError {
        await MainActor.run {
          guard self.pendingChatOpenRequestID == requestID else { return }
          self.clearPendingChatOpenState(cancelTask: false)
        }
      } catch {
        await MainActor.run {
          guard self.pendingChatOpenRequestID == requestID else { return }
          guard self.activeTab == requestTab else {
            self.clearPendingChatOpenState(cancelTask: false)
            return
          }
          self.preparedChatPayloads.removeValue(forKey: peer)
          self.clearPendingChatOpenState(cancelTask: false)
          self.navigate(to: .chat(peer: peer))
        }
      }
    }
  }

  func goBack() {
    guard canGoBack else { return }
    clearPendingChatOpenState()
    let current = history.removeLast()
    forwardHistory.append(current)

    if let last = history.last {
      updateActiveTab(to: last)
    }
  }

  func goForward() {
    guard let next = forwardHistory.popLast() else { return }
    clearPendingChatOpenState()
    history.append(next)
    updateActiveTab(to: next)
  }

  func removeTab(at index: Int) {
    guard index < tabs.count else { return }
    guard index != 0 else { return } // keep Home pinned
    guard tabs.count > 1 else { return }

    let previousActiveTab = activeTab
    let removedTab = tabs[index]
    tabs.remove(at: index)

    if activeTabIndex >= tabs.count {
      activeTabIndex = tabs.count - 1
    } else if activeTabIndex > index {
      activeTabIndex -= 1
    }

    history.removeAll { $0.tab == removedTab }
    forwardHistory.removeAll { $0.tab == removedTab }
    lastRoutes.removeValue(forKey: removedTab)

    if previousActiveTab != activeTab {
      activateTab(at: activeTabIndex)
    } else if history.isEmpty {
      activateTab(at: activeTabIndex)
    }

    saveStateLowPriority()
  }

  func setActiveTab(index: Int) {
    guard index < tabs.count else { return }
    activateTab(at: index)
  }

  /// Open (or activate) a space tab by id; updates the tab name if it changed.
  func openSpace(_ space: Space) {
    // If tab exists, activate it and refresh the name if different
    if let existingIndex = tabs.firstIndex(where: { tab in
      if case let .space(id, _) = tab { return id == space.id }
      return false
    }) {
      if case let .space(id, name) = tabs[existingIndex], name != space.displayName {
        tabs[existingIndex] = .space(id: id, name: space.displayName)
      }
      activateTab(at: existingIndex)
      return
    }

    // Otherwise append a new tab and activate it
    tabs.append(.space(id: space.id, name: space.displayName))
    activateTab(at: tabs.count - 1, routeOverride: .empty)
  }

  @MainActor
  func openChat(peer: Peer, space: Space? = nil, database: AppDatabase = .shared) async {
    switch peer {
      case let .thread(threadId):
        let resolvedSpaceId: Int64? = if let space {
          space.id
        } else {
          await resolveThreadSpaceId(threadId: threadId, database: database)
        }

        if let space {
          openSpace(space)
        } else if let spaceId = resolvedSpaceId {
          await openSpace(id: spaceId, database: database)
        } else {
          openHomeTabIfNeeded()
        }

        requestOpenChat(peer: peer, database: database)

      case let .user(userId):
        if let activeSpaceId = activeTab.spaceId {
          let isMember = await isMemberOfSpace(userId: userId, spaceId: activeSpaceId, database: database)
          if isMember == false {
            openHomeTabIfNeeded()
          }
        }
        requestOpenChat(peer: peer, database: database)
    }
  }

  // MARK: - Perf signposts

  private func beginChatNavigationSignpost(peer: Peer) {
    if let activeChatNavigation {
      // PERF MARK: end superseded chat navigation signpost (remove when done).
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
    // PERF MARK: begin chat navigation signpost (remove when done).
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
    // PERF MARK: end chat navigation signpost (remove when done).
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

  // MARK: - Initialization & Persistence

  init() {
    // UNCOMMENT THIS WHEN WE HAVE A PERSISTENT STATE
    loadState()
    if history.isEmpty {
      activateTab(at: activeTabIndex)
    }
  }

  // File URL for persistence
  private var stateFileURL: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("nav_state_v2.json")
  }

  struct Persisted: Codable {
    var tabs: [TabId]
    var activeTabIndex: Int
  }

  private func saveState() {
    let state = Persisted(
      tabs: tabs,
      activeTabIndex: activeTabIndex
    )

    do {
      let encoder = JSONEncoder()
      let data = try encoder.encode(state)
      try data.write(to: stateFileURL)
    } catch {
      Log.shared.error("Failed to save navigation state: \(error.localizedDescription)")
    }
  }

  private func loadState() {
    guard FileManager.default.fileExists(atPath: stateFileURL.path) else { return }

    do {
      let data = try Data(contentsOf: stateFileURL)
      let decoder = JSONDecoder()
      let state = try decoder.decode(Persisted.self, from: data)

      // Update state
      tabs = state.tabs
      activeTabIndex = state.activeTabIndex
      normalizeState()
      log.debug("Loaded nav state \(tabs.count) tabs, active \(activeTabIndex)")
    } catch {
      Log.shared.error("Failed to load navigation state: \(error.localizedDescription)")
      // If loading fails, reset to default state
      reset()
    }
  }

  // Called on logout
  func reset() {
    clearPendingChatOpenState()
    preparedChatPayloads.removeAll(keepingCapacity: true)
    tabs = [.home]
    activeTabIndex = 0
    history = []
    forwardHistory = []

    // Delete persisted state file
    try? FileManager.default.removeItem(at: stateFileURL)
  }

  // Utility
  private func saveStateLowPriority() {
    saveStateTask?.cancel()
    saveStateTask = Task(priority: .background) {
      saveState()
    }
  }

  private func clearPendingChatOpenState(cancelTask: Bool = true) {
    if cancelTask {
      pendingChatOpenTask?.cancel()
    }
    pendingChatOpenTask = nil
    pendingChatOpenRequestID = nil
    pendingChatPeer = nil
  }

  /// Centralized tab activation that restores the last route for that tab (or .empty).
  private func activateTab(at index: Int, routeOverride: Nav2Route? = nil) {
    guard index < tabs.count else { return }
    clearPendingChatOpenState()

    let targetTab = tabs[index]
    activeTabIndex = index

    let defaultRoute: Nav2Route = .empty
    let targetRoute = routeOverride ?? lastRoutes[targetTab] ?? defaultRoute
    lastRoutes[targetTab] = targetRoute

    if recordNavigation(route: targetRoute, tab: targetTab, isImplicit: true, replaceImplicit: false) {
      forwardHistory.removeAll()
    }

    saveStateLowPriority()
  }

  private func updateActiveTab(to entry: Nav2Entry) {
    guard let tabIndex = tabs.firstIndex(of: entry.tab) else {
      return
    }
    activeTabIndex = tabIndex
    lastRoutes[entry.tab] = entry.route
  }

  @discardableResult
  private func recordNavigation(
    route: Nav2Route,
    tab: TabId,
    isImplicit: Bool,
    replaceImplicit: Bool
  ) -> Bool {
    let entry = Nav2Entry(route: route, tab: tab, isImplicit: isImplicit)

    guard let lastIndex = history.indices.last else {
      history.append(entry)
      return true
    }

    let last = history[lastIndex]

    if replaceImplicit, last.tab == tab, last.isImplicit, !isImplicit {
      history[lastIndex] = entry
      return true
    }

    if last.tab == tab, last.route == route, last.isImplicit == isImplicit {
      return false
    }

    history.append(entry)
    return true
  }

  private func normalizeState() {
    // Preserve the active tab identity if possible.
    let currentTab = tabs.indices.contains(activeTabIndex) ? tabs[activeTabIndex] : .home

    if tabs.isEmpty {
      tabs = [.home]
      activeTabIndex = 0
      return
    }

    var uniqueTabs: [TabId] = []
    uniqueTabs.reserveCapacity(tabs.count)
    for tab in tabs where !uniqueTabs.contains(tab) {
      uniqueTabs.append(tab)
    }
    tabs = uniqueTabs

    if !tabs.contains(.home) {
      tabs.insert(.home, at: 0)
    } else if let homeIndex = tabs.firstIndex(of: .home), homeIndex != 0 {
      tabs.remove(at: homeIndex)
      tabs.insert(.home, at: 0)
    }

    if let newIndex = tabs.firstIndex(of: currentTab) {
      activeTabIndex = newIndex
    } else {
      activeTabIndex = 0
    }
  }

  @MainActor
  private func openHomeTabIfNeeded() {
    if case .home = activeTab { return }
    if let index = tabs.firstIndex(of: .home) {
      setActiveTab(index: index)
    }
  }

  @MainActor
  private func openSpace(id spaceId: Int64, database: AppDatabase) async {
    if let space = await fetchSpace(id: spaceId, database: database) {
      openSpace(space)
    } else {
      openSpace(Space(id: spaceId, name: "Space", date: Date()))
    }
  }

  private func resolveThreadSpaceId(threadId: Int64, database: AppDatabase) async -> Int64? {
    do {
      let chat = try await database.reader.read { db in
        try Chat.filter(Column("id") == threadId).fetchOne(db)
      }
      return chat?.spaceId
    } catch {
      log.error("Failed to resolve thread space id", error: error)
      return nil
    }
  }

  private func fetchSpace(id spaceId: Int64, database: AppDatabase) async -> Space? {
    do {
      return try await database.reader.read { db in
        try Space.fetchOne(db, id: spaceId)
      }
    } catch {
      log.error("Failed to fetch space \(spaceId)", error: error)
      return nil
    }
  }

  private func isMemberOfSpace(userId: Int64, spaceId: Int64, database: AppDatabase) async -> Bool {
    do {
      let member = try await database.reader.read { db in
        try Member
          .filter(Member.Columns.userId == userId)
          .filter(Member.Columns.spaceId == spaceId)
          .fetchOne(db)
      }
      return member != nil
    } catch {
      log.error("Failed to check membership for user \(userId) in space \(spaceId)", error: error)
      return false
    }
  }
}
