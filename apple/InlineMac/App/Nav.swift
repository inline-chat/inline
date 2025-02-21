import Combine
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
  public var history: [NavEntry] = []

  public var forwardHistory: [NavEntry] = []

  // UI State Publishers For AppKit
  var canGoBackPublisher: CurrentValueSubject<Bool, Never> = CurrentValueSubject(false)
  var canGoForwardPublisher: CurrentValueSubject<Bool, Never> = CurrentValueSubject(false)
  var currentRoutePublisher: CurrentValueSubject<NavEntry.Route, Never> = CurrentValueSubject(.empty)
  var currentSpaceIdPublisher: CurrentValueSubject<Int64?, Never> = CurrentValueSubject(nil)

  // UI State
  @Published var canGoBack: Bool = false { didSet { canGoBackPublisher.send(canGoBack) } }
  @Published var canGoForward: Bool = false { didSet { canGoForwardPublisher.send(canGoForward) } }
  @Published var currentRoute: NavEntry.Route = .empty { didSet { currentRoutePublisher.send(currentRoute) } }
  @Published var currentSpaceId: Int64? = nil { didSet { currentSpaceIdPublisher.send(currentSpaceId) } }

  private init() {
    loadState()
  }

  private func reflectHistoryChange() {
    // Update can go back
    let nextCanGoBack = history.count > 1 // below 1 must be go with esc
    if canGoBack != nextCanGoBack {
      canGoBack = nextCanGoBack
    }

    // Update can go forward
    let nextCanGoForward = forwardHistory.count > 0
    if canGoForward != nextCanGoForward {
      canGoForward = nextCanGoForward
    }

    // Update current route
    currentRoute = history.last?.route ?? .empty

    // Update current space id
    currentSpaceId = history.last?.spaceId

    // Persist
    saveStateLowPrio()
  }
}

// MARK: - Navigation APIs

extension Nav {
  public func openSpace(_ spaceId: Int64) {
    // TODO: Implement a caching for last viewed route in that space and restore that instead of opening .empty
    let entry = NavEntry(route: .empty, spaceId: spaceId)
    history.append(entry)

    reflectHistoryChange()
  }

  public func openHome() {
    // TODO: Implement a caching for last viewed route in home
    let entry = NavEntry(route: .empty, spaceId: nil)
    history.append(entry)

    reflectHistoryChange()
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

    reflectHistoryChange()
  }

  public func goBack() {
    print("goBack")
    print("history: \(history)")
    guard history.count > 0 else { return }

    let current = history.removeLast()
    forwardHistory.append(current)

    reflectHistoryChange()
  }

  public func goForward() {
    guard forwardHistory.count >= 1 else { return }

    let current = forwardHistory.removeLast()
    history.append(current)

    reflectHistoryChange()
  }

  public func handleEsc() {
    if history.count == 1 {
      history = []
      forwardHistory = []
      reflectHistoryChange()
    } else {
      open(.empty)
    }
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
    var lastEntry: NavEntry?
  }

  private func saveState() {
    let state = Persisted(
      lastEntry: history.last
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
      history = if let navEntry = state.lastEntry { [navEntry] } else { [] }

      reflectHistoryChange()
    } catch {
      Log.shared.error("Failed to load navigation state: \(error.localizedDescription)")
      // If loading fails, reset to default state
      reset()
    }
  }

  // Called on logout
  func reset() {
    history = []

    reflectHistoryChange()

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
