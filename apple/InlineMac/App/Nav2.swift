import Combine
import Foundation
import InlineKit
import Logger
import Observation

enum Nav2Route: Equatable, Hashable, Codable {
  case empty
  case chat(peer: Peer)
  case chatInfo(peer: Peer)
  case profile(userId: Int64)
  case createSpace
  case newChat
  case inviteToSpace
}

enum TabId: Hashable, Codable {
  case home
  case space(id: Int64, name: String)
  // case chat(Int64, spaceId: Int64)

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
}

/// Manages navigation per window
@Observable class Nav2 {
  @ObservationIgnored private let log = Log.scoped("Nav2", enableTracing: false)
  @ObservationIgnored private var saveStateTask: Task<Void, Never>?

  // MARK: - State

  var tabs: [TabId] = [.home, .space(id: 1, name: "Inline")]

  var activeTabIndex: Int = 0

  /// History of navigation entries, current entry is last item in the history array
  var history: [Nav2Entry] = []

  var forwardHistory: [Nav2Entry] = []

  var activeSpaceId: Int64? {
    history.last?.tab.spaceId
  }

  var activeTab: TabId {
    tabs[activeTabIndex]
  }

  // MARK: - Methods

  func navigate(to route: Nav2Route) {
    log.trace("Navigating to \(route)")
    history.append(Nav2Entry(route: route, tab: activeTab))
  }

  func removeTab(at index: Int) {
    guard index < tabs.count else { return }
    guard tabs.count > 1 else { return }

    tabs.remove(at: index)

    if activeTabIndex >= tabs.count {
      activeTabIndex = tabs.count - 1
    } else if activeTabIndex > index {
      activeTabIndex -= 1
    }

    saveStateLowPriority()
  }

  func setActiveTab(index: Int) {
    guard index < tabs.count else { return }
    activeTabIndex = index
    saveStateLowPriority()
  }

  // MARK: - Initialization & Persistence

  init() {
    // UNCOMMENT THIS WHEN WE HAVE A PERSISTENT STATE
    // loadState()
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

      print("loaded nav state \(state)")

      // Update state
      tabs = state.tabs
      activeTabIndex = state.activeTabIndex
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
}
