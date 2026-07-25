import Foundation
import Observation

/// A generic navigation model that provides tab-based navigation with persistent state.
///
/// This model automatically persists the selected tab and navigation paths for each tab
/// to UserDefaults. State is restored when the model is initialized.
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
      savePersistentState()
    }
  }

  public var selectedTab: Tab {
    didSet {
      savePersistentState()
    }
  }

  public var presentedSheet: Sheet?

  // Store the initial tab for proper reset behavior
  @ObservationIgnored private let initialTab: Tab

  // Persistence keys
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let stateKey: String
  @ObservationIgnored private let pathsKey: String
  @ObservationIgnored private let selectedTabKey: String
  @ObservationIgnored private let presentedSheetKey: String
  @ObservationIgnored private let encoder = JSONEncoder()
  @ObservationIgnored private let decoder = JSONDecoder()

  /// Initialize the navigation model with persistence support
  /// - Parameters:
  ///   - initialTab: The default tab to select if no persisted state exists
  public convenience init(initialTab: Tab) {
    self.init(initialTab: initialTab, defaults: .standard, keyPrefix: "AppRouter")
  }

  init(initialTab: Tab, defaults: UserDefaults, keyPrefix: String) {
    self.initialTab = initialTab
    self.defaults = defaults
    stateKey = "\(keyPrefix)_state_v1"
    pathsKey = "\(keyPrefix)_paths"
    selectedTabKey = "\(keyPrefix)_selectedTab"
    presentedSheetKey = "\(keyPrefix)_presentedSheet"
    selectedTab = initialTab

    if let stateData = defaults.data(forKey: stateKey),
       let state = try? decoder.decode(PersistentState.self, from: stateData) {
      paths = state.paths
      selectedTab = state.selectedTab
    } else {
      loadLegacyPersistentState()
      savePersistentState()
    }

    clearPersistedSheet()
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

  // MARK: - Persistence

  private func savePersistentState() {
    let state = PersistentState(paths: paths, selectedTab: selectedTab)
    if let data = try? encoder.encode(state) {
      defaults.set(data, forKey: stateKey)
    }
    clearPersistedSheet()
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
    paths = [:]
    selectedTab = initialTab
    presentedSheet = nil

    // Clear persisted data
    defaults.removeObject(forKey: stateKey)
    defaults.removeObject(forKey: pathsKey)
    defaults.removeObject(forKey: selectedTabKey)
    defaults.removeObject(forKey: presentedSheetKey)
  }
}
