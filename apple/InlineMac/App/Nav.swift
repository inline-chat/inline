import Foundation
import InlineKit
import Logger

struct NavEntry: Hashable, Codable, Equatable {
  var route: Route
  var spaceId: Int64?

  enum Route: Hashable, Codable, Equatable {
    case empty
    case chat(peer: Peer)
    case chatInfo(peer: Peer)
    case profile(userInfo: UserInfo)

    static func == (lhs: Route, rhs: Route) -> Bool {
      switch (lhs, rhs) {
        case (.empty, .empty):
          true
        case let (.chat(lhsPeer), .chat(rhsPeer)):
          lhsPeer == rhsPeer
        case let (.chatInfo(lhsPeer), .chatInfo(rhsPeer)):
          lhsPeer == rhsPeer
        case let (.profile(lhsUser), .profile(rhsUser)):
          lhsUser == rhsUser
        default:
          false
      }
    }
  }
}

/// Manages navigation per window
class Nav: ObservableObject {
  static let main = Nav()

  private let log = Log.scoped("Nav", enableTracing: false)
  private let maxHistoryLength = 200
  private var saveStateTask: Task<Void, Never>? = nil

  // TODO: support multi-window
  // to support that, we need to store state per window, and disable persist outside of main window
  // and initialize with the state provided by the window
  // public let isMainWindow = true

  // Nav State

  /// History of navigation entries, current entry is last item in the history array
  public var history: [NavEntry] = [] {
    didSet {
      // Update current route
      currentRoute = history.last?.route ?? .empty

      // Update current space id
      currentSpaceId = history.last?.spaceId

      // Update can go back
      let nextCanGoBack = history.count > 1
      if canGoBack != nextCanGoBack {
        canGoBack = nextCanGoBack
      }
    }
  }

  public var forwardHistory: [NavEntry] = [] {
    didSet {
      // Update can go forward
      let nextCanGoForward = forwardHistory.count > 0
      if canGoForward != nextCanGoForward {
        canGoForward = nextCanGoForward
      }
    }
  }

  // UI State
  @Published var canGoBack: Bool = false
  @Published var canGoForward: Bool = false
  @Published var currentRoute: NavEntry.Route = .empty
  @Published var currentSpaceId: Int64? = nil

  private init() {
    loadState()
  }
}

// MARK: - Navigation APIs

extension Nav {
  public func openSpace(_ spaceId: Int64) {
    // TODO: Implement a caching for last viewed route in that space and restore that instead of opening .empty
    let entry = NavEntry(route: .empty, spaceId: spaceId)
    history.append(entry)
  }

  public func openHome() {
    // TODO: Implement a caching for last viewed route in home
    let entry = NavEntry(route: .empty, spaceId: nil)
    history.append(entry)
  }

  public func open(_ route: NavEntry.Route) {
    let entry = NavEntry(route: route, spaceId: currentSpaceId)
    history.append(entry)

    // limit history
    if history.count > maxHistoryLength {
      history.removeFirst()
    }

    // forward history is cleared on open
    forwardHistory.removeAll()
  }

  public func goBack() {
    guard history.count > 1 else { return }

    let current = history.removeLast()
    forwardHistory.append(current)
  }

  public func goForward() {
    guard forwardHistory.count >= 1 else { return }

    let current = forwardHistory.removeLast()
    history.append(current)
  }
}

// MARK: - Persistance

extension Nav {
  // File URL for persistence
  private var stateFileURL: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("nav_state.json")
  }

  struct Persisted: Codable {
    var history: [NavEntry]
    var forwardHistory: [NavEntry]
  }

  private func saveState() {
    let state = Persisted(
      history: history,
      forwardHistory: forwardHistory
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
      history = state.history
      forwardHistory = state.forwardHistory
    } catch {
      Log.shared.error("Failed to load navigation state: \(error.localizedDescription)")
      // If loading fails, reset to default state
      reset()
    }
  }

  // Called on logout
  func reset() {
    history = []

    // Delete persisted state file
    try? FileManager.default.removeItem(at: stateFileURL)
  }

  // Utility
  private func saveStateLowPrio() {
    saveStateTask?.cancel()
    saveStateTask = Task(priority: .background) {
      saveState()
    }
  }
}
