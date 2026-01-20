import Combine
import Foundation
import InlineKit
import Logger
import Observation

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

  // MARK: - State

  var tabs: [TabId] = [.home]

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
    return activeTab == .home ? .spaces : .empty
  }

  // MARK: - Methods

  func navigate(to route: Nav2Route) {
    log.trace("Navigating to \(route)")
    lastRoutes[activeTab] = route
    _ = recordNavigation(route: route, tab: activeTab, isImplicit: false, replaceImplicit: true)
    forwardHistory.removeAll()
  }

  func goBack() {
    guard canGoBack else { return }
    let current = history.removeLast()
    forwardHistory.append(current)

    if let last = history.last {
      updateActiveTab(to: last)
    }
  }

  func goForward() {
    guard let next = forwardHistory.popLast() else { return }
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

  /// Centralized tab activation that restores the last route for that tab (or .empty).
  private func activateTab(at index: Int, routeOverride: Nav2Route? = nil) {
    guard index < tabs.count else { return }

    let targetTab = tabs[index]
    activeTabIndex = index

    let defaultRoute: Nav2Route = targetTab == .home ? .spaces : .empty
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
}
