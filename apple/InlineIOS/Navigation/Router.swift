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
      navigationStateDidChange()
    }
  }

  public var selectedTab: Tab {
    didSet {
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
