import Foundation
import Playgrounds
import SwiftUI

/// A generic navigation model that provides tab-based navigation with persistent state.
///
/// This model automatically persists the selected tab, navigation paths for each tab,
/// and any presented sheet to UserDefaults. State is restored when the model is initialized.
///
/// - Parameters:
///   - Tab: Must conform to TabType and Codable
///   - Destination: Must conform to DestinationType and Codable
///   - Sheet: Must conform to SheetType and Codable
@Observable
@MainActor
public final class NavigationModel<Tab: TabType, Destination: DestinationType, Sheet: SheetType> {
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

  public var presentedSheet: Sheet? {
    didSet {
      savePersistentState()
    }
  }

  // Persistence keys
  private let pathsKey: String
  private let selectedTabKey: String
  private let presentedSheetKey: String

  /// Initialize the navigation model with persistence support
  /// - Parameters:
  ///   - initialTab: The default tab to select if no persisted state exists
  public init(initialTab: Tab) {
    selectedTab = initialTab
    pathsKey = "AppRouter_paths"
    selectedTabKey = "AppRouter_selectedTab"
    presentedSheetKey = "AppRouter_presentedSheet"

    loadPersistentState()
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
    savePaths()
    saveSelectedTab()
    savePresentedSheet()
  }

  private func loadPersistentState() {
    loadPaths()
    loadSelectedTab()
    loadPresentedSheet()
  }

  // MARK: - Paths Persistence

  private func savePaths() {
    let currentPaths = paths
    let pathsKey = pathsKey

    Task.detached(priority: .background) {
      if let pathsData = try? JSONEncoder().encode(currentPaths) {
        UserDefaults.standard.set(pathsData, forKey: pathsKey)
      }
    }
  }

  private func loadPaths() {
    if let pathsData = UserDefaults.standard.data(forKey: pathsKey),
       let decodedPaths = try? JSONDecoder().decode([Tab: [Destination]].self, from: pathsData)
    {
      paths = decodedPaths
    }
  }

  // MARK: - Selected Tab Persistence

  private func saveSelectedTab() {
    let currentSelectedTab = selectedTab
    let selectedTabKey = selectedTabKey

    Task.detached(priority: .background) {
      if let selectedTabData = try? JSONEncoder().encode(currentSelectedTab) {
        UserDefaults.standard.set(selectedTabData, forKey: selectedTabKey)
      }
    }
  }

  private func loadSelectedTab() {
    if let selectedTabData = UserDefaults.standard.data(forKey: selectedTabKey),
       let decodedSelectedTab = try? JSONDecoder().decode(Tab.self, from: selectedTabData)
    {
      selectedTab = decodedSelectedTab
    }
  }

  // MARK: - Presented Sheet Persistence

  private func savePresentedSheet() {
    let currentPresentedSheet = presentedSheet
    let presentedSheetKey = presentedSheetKey

    Task.detached(priority: .background) {
      if let presentedSheetData = try? JSONEncoder().encode(currentPresentedSheet) {
        UserDefaults.standard.set(presentedSheetData, forKey: presentedSheetKey)
      }
    }
  }

  private func loadPresentedSheet() {
    if let presentedSheetData = UserDefaults.standard.data(forKey: presentedSheetKey),
       let decodedPresentedSheet = try? JSONDecoder().decode(Sheet?.self, from: presentedSheetData)
    {
      presentedSheet = decodedPresentedSheet
    }
  }

  /// Reset all navigation state and clear persistence
  public func reset() {
    paths = [:]
    selectedTab = Tab.allCases.first ?? selectedTab
    presentedSheet = nil

    // Clear persisted data
    UserDefaults.standard.removeObject(forKey: pathsKey)
    UserDefaults.standard.removeObject(forKey: selectedTabKey)
    UserDefaults.standard.removeObject(forKey: presentedSheetKey)
  }
}
