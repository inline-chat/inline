import Foundation
import Observation

public enum NavigationPersistenceMode: Sendable {
  case userDefaults
  case externallyManaged
}

/// A generic navigation model that provides tab-based navigation with optional persistence.
///
/// The owner can use built-in UserDefaults persistence or store encoded snapshots in
/// scene-scoped storage so each window restores its own tab and navigation paths.
///
/// - Parameters:
///   - Tab: Must conform to TabType and Codable
///   - Destination: Must conform to DestinationType and Codable
///   - Sheet: Must conform to SheetType and Codable
@Observable
@MainActor
public final class NavigationModel<Tab: TabType, Destination: DestinationType, Sheet: SheetType> {
  private struct PersistentState: Codable {
    let paths: [Tab: [Destination]]
    let selectedTab: Tab
  }

  private var paths: [Tab: [Destination]] = [:] {
    didSet {
      recordNavigation(from: HistoryEntry(tab: selectedTab, path: oldValue[selectedTab] ?? []))
      navigationStateDidChange()
    }
  }

  public var selectedTab: Tab {
    didSet {
      recordNavigation(from: HistoryEntry(tab: oldValue, path: paths[oldValue] ?? []))
      navigationStateDidChange()
    }
  }

  /// Changes whenever the selected tab or a navigation path changes. Scene owners
  /// use this to persist one router snapshot per window.
  public private(set) var persistenceRevision = 0

  /// Changes when an external route should dismiss transient UI, including when
  /// the destination is already visible and the navigation path is deduplicated.
  public private(set) var presentationResetRevision = 0

  public var presentedSheet: Sheet?

  /// Opt-in, in-memory history for a scene. Phone navigation leaves this disabled.
  public var tracksHistory = false {
    didSet {
      if tracksHistory != oldValue { clearHistory() }
    }
  }

  private struct HistoryEntry: Equatable {
    let tab: Tab
    let path: [Destination]
  }

  private var backHistory: [HistoryEntry] = []
  private var forwardHistory: [HistoryEntry] = []
  @ObservationIgnored private var isApplyingHistory = false
  @ObservationIgnored private var isApplyingNativeNavigation = false

  public var canGoBack: Bool { tracksHistory && (!backHistory.isEmpty || selectedTabPath.count > 1) }
  public var canGoForward: Bool { tracksHistory && !forwardHistory.isEmpty }

  public func goBack() {
    guard tracksHistory else { return }
    if let entry = backHistory.popLast() {
      forwardHistory.append(currentHistoryEntry)
      trimHistory(&forwardHistory)
      applyHistory(entry)
    } else if selectedTabPath.count > 1 {
      // A restored nested route has no transient history, but must still be escapable.
      setPathFromNavigation(Array(selectedTabPath.dropLast()))
    }
  }

  public func goForward() {
    guard tracksHistory, let entry = forwardHistory.popLast() else { return }
    backHistory.append(currentHistoryEntry)
    trimHistory(&backHistory)
    applyHistory(entry)
  }

  /// History never crosses an account, restoration, or workspace boundary.
  public func clearHistory() {
    backHistory = []
    forwardHistory = []
  }

  /// Remove unavailable destinations without recording cleanup as a new visit.
  /// Only history-enabled scenes use this; phone navigation retains its existing pop behavior.
  public func removeInvalidDestinations(where isInvalid: (Destination) -> Bool) {
    guard tracksHistory else { return }

    func validHistory(_ entries: [HistoryEntry]) -> [HistoryEntry] {
      var result: [HistoryEntry] = []
      for entry in entries where !entry.path.contains(where: isInvalid) {
        // Removing a visit can bring identical neighboring snapshots together.
        if result.last != entry { result.append(entry) }
      }
      return result
    }

    backHistory = validHistory(backHistory)
    forwardHistory = validHistory(forwardHistory)
    // A removed parent also invalidates its descendants, including inactive tabs.
    let validPaths = paths.mapValues { path in
      Array(path.prefix { !isInvalid($0) })
    }
    if validPaths != paths {
      isApplyingHistory = true
      paths = validPaths
      isApplyingHistory = false
    }
    // Cleanup may leave the current route at the top of either history stack.
    while backHistory.last == currentHistoryEntry { backHistory.removeLast() }
    while forwardHistory.last == currentHistoryEntry { forwardHistory.removeLast() }
  }

  private var currentHistoryEntry: HistoryEntry {
    HistoryEntry(tab: selectedTab, path: selectedTabPath)
  }

  private func recordNavigation(from previous: HistoryEntry) {
    guard tracksHistory, !isRestoring, !isApplyingHistory else { return }
    let current = currentHistoryEntry
    guard current != previous else { return }

    // Native Back (including a multi-level pop) is history traversal, not a
    // new visit. Keep Forward useful after the system back button or gesture.
    if isApplyingNativeNavigation,
       current.tab == previous.tab,
       current.path.count < previous.path.count,
       previous.path.starts(with: current.path) {
      forwardHistory.append(previous)
      if let index = backHistory.lastIndex(of: current) {
        forwardHistory.append(contentsOf: backHistory[(index + 1)...].reversed())
        backHistory.removeSubrange(index...)
      }
    } else {
      backHistory.append(previous)
      forwardHistory = []
    }
    trimHistory(&backHistory)
    trimHistory(&forwardHistory)
  }

  private func trimHistory(_ history: inout [HistoryEntry]) {
    if history.count > 100 {
      history.removeFirst(history.count - 100)
    }
  }

  private func applyHistory(_ entry: HistoryEntry) {
    isApplyingHistory = true
    paths[entry.tab] = entry.path
    selectedTab = entry.tab
    isApplyingHistory = false
  }

  // Store the initial tab for proper reset behavior
  @ObservationIgnored private let initialTab: Tab

  // Persistence keys
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let persistenceMode: NavigationPersistenceMode
  @ObservationIgnored private let stateKey: String
  @ObservationIgnored private let pathsKey: String
  @ObservationIgnored private let selectedTabKey: String
  @ObservationIgnored private let presentedSheetKey: String
  @ObservationIgnored private let encoder = JSONEncoder()
  @ObservationIgnored private let decoder = JSONDecoder()
  @ObservationIgnored private var isRestoring = false

  /// Initialize the navigation model with persistence support
  /// - Parameters:
  ///   - initialTab: The default tab to select if no persisted state exists
  public convenience init(initialTab: Tab) {
    self.init(
      initialTab: initialTab,
      persistence: .userDefaults,
      restoresPersistedState: true
    )
  }

  public convenience init(
    initialTab: Tab,
    persistence: NavigationPersistenceMode,
    restoresPersistedState: Bool = true
  ) {
    self.init(
      initialTab: initialTab,
      defaults: .standard,
      keyPrefix: "AppRouter",
      persistence: persistence,
      restoresPersistedState: restoresPersistedState
    )
  }

  init(
    initialTab: Tab,
    defaults: UserDefaults,
    keyPrefix: String,
    persistence: NavigationPersistenceMode = .userDefaults,
    restoresPersistedState: Bool = true
  ) {
    self.initialTab = initialTab
    self.defaults = defaults
    persistenceMode = persistence
    stateKey = "\(keyPrefix)_state_v1"
    pathsKey = "\(keyPrefix)_paths"
    selectedTabKey = "\(keyPrefix)_selectedTab"
    presentedSheetKey = "\(keyPrefix)_presentedSheet"
    selectedTab = initialTab

    if restoresPersistedState,
       let stateData = defaults.data(forKey: stateKey),
       let state = try? decoder.decode(PersistentState.self, from: stateData) {
      paths = state.paths
      selectedTab = state.selectedTab
    } else if restoresPersistedState {
      loadLegacyPersistentState()
      if persistenceMode == .userDefaults {
        savePersistentState()
      }
    }

    if persistenceMode == .userDefaults {
      clearPersistedSheet()
    }
  }

  public subscript(tab: Tab) -> [Destination] {
    get { paths[tab] ?? [] }
    set {
      paths[tab] = newValue
    }
  }

  public var selectedTabPath: [Destination] {
    paths[selectedTab] ?? []
  }

  /// Only a NavigationStack binding uses this path. Programmatic replacements
  /// remain new visits, even when the replacement is a prefix of the old route.
  public func setPathFromNavigation(_ path: [Destination], for tab: Tab? = nil) {
    isApplyingNativeNavigation = true
    paths[tab ?? selectedTab] = path
    isApplyingNativeNavigation = false
  }

  /// Replaces a completed flow without adding that flow to Back history.
  /// The existing Back stack remains available; a new branch clears Forward.
  public func replaceCurrentPath(with path: [Destination], for tab: Tab? = nil) {
    let targetTab = tab ?? selectedTab
    isApplyingHistory = true
    paths[targetTab] = path
    isApplyingHistory = false
    if tracksHistory {
      forwardHistory = []
    }
  }

  /// Clears route state at an account/workspace boundary without creating
  /// synthetic Back visits. This is opt-in at the iPad call site.
  public func resetNavigationBoundary(
    pathsFor tabs: [Tab],
    selecting tab: Tab? = nil,
    path: [Destination] = []
  ) {
    clearHistory()
    isRestoring = true
    var nextPaths = paths
    for targetTab in tabs {
      nextPaths[targetTab] = []
    }
    if let tab {
      nextPaths[tab] = path
    }
    paths = nextPaths
    if let tab {
      selectedTab = tab
    }
    isRestoring = false
    navigationStateDidChange()
  }

  public func popToRoot(for tab: Tab? = nil) {
    let targetTab = tab ?? selectedTab
    paths[targetTab] = []
  }

  public func pop(for tab: Tab? = nil) {
    let targetTab = tab ?? selectedTab
    if paths[targetTab]?.isEmpty == false {
      paths[targetTab]?.removeLast()
    }
  }

  public func push(_ destination: Destination, for tab: Tab? = nil) {
    let targetTab = tab ?? selectedTab
    if paths[targetTab] == nil {
      paths[targetTab] = [destination]
    } else {
      paths[targetTab]?.append(destination)
    }
  }

  public func presentSheet(_ sheet: Sheet) {
    presentedSheet = sheet
  }

  public func dismissSheet() {
    presentedSheet = nil
  }

  public func resetTransientPresentation() {
    presentedSheet = nil
    presentationResetRevision &+= 1
  }

  // MARK: - Persistence

  public func encodedPersistentState() -> Data? {
    try? encoder.encode(PersistentState(paths: paths, selectedTab: selectedTab))
  }

  @discardableResult
  public func restorePersistentState(from data: Data) -> Bool {
    guard let state = try? decoder.decode(PersistentState.self, from: data) else {
      return false
    }

    clearHistory()
    isRestoring = true
    paths = state.paths
    selectedTab = state.selectedTab
    isRestoring = false
    navigationStateDidChange()
    return true
  }

  private func navigationStateDidChange() {
    guard !isRestoring else { return }
    persistenceRevision &+= 1
    if persistenceMode == .userDefaults {
      savePersistentState()
    }
  }

  private func savePersistentState() {
    let state = PersistentState(paths: paths, selectedTab: selectedTab)
    if let data = try? encoder.encode(state) {
      defaults.set(data, forKey: stateKey)
    }
    if persistenceMode == .userDefaults {
      clearPersistedSheet()
    }
  }

  private func loadLegacyPersistentState() {
    if let pathsData = defaults.data(forKey: pathsKey),
       let decodedPaths = try? decoder.decode([Tab: [Destination]].self, from: pathsData) {
      paths = decodedPaths
    }

    if let selectedTabData = defaults.data(forKey: selectedTabKey),
       let decodedSelectedTab = try? decoder.decode(Tab.self, from: selectedTabData) {
      selectedTab = decodedSelectedTab
    }
  }

  // MARK: - Presented Sheet Persistence

  private func clearPersistedSheet() {
    defaults.removeObject(forKey: presentedSheetKey)
  }

  /// Reset all navigation state and clear persistence
  public func reset() {
    clearHistory()
    isRestoring = true
    paths = [:]
    selectedTab = initialTab
    presentedSheet = nil
    isRestoring = false

    // Clear persisted data
    defaults.removeObject(forKey: stateKey)
    defaults.removeObject(forKey: pathsKey)
    defaults.removeObject(forKey: selectedTabKey)
    defaults.removeObject(forKey: presentedSheetKey)
    navigationStateDidChange()
  }
}
