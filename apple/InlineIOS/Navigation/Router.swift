import Foundation
import InlineKit
#if canImport(Playgrounds)
import Playgrounds
#endif
import SwiftUI

/// A navigation model that provides stack-based navigation with persistent state.
///
/// This model automatically persists the navigation path and any presented sheet
/// to UserDefaults. State is restored when the model is initialized.
///
/// - Parameters:
///   - Destination: Must conform to DestinationType and Codable
///   - Sheet: Must conform to SheetType and Codable
@Observable
@MainActor
public final class NavigationModel<Destination: DestinationType, Sheet: SheetType> {
  public var path: [Destination] = [] {
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
  private let pathKey: String
  private let presentedSheetKey: String

  /// Initialize the navigation model with persistence support
  public init() {
    pathKey = "AppRouter_path"
    presentedSheetKey = "AppRouter_presentedSheet"

    loadPersistentState()
  }

  public func popToRoot() {
    path = []
  }

  public func pop() {
    if !path.isEmpty {
      path.removeLast()
    }
  }

  public func push(_ destination: Destination) {
    path.append(destination)
  }

  public func presentSheet(_ sheet: Sheet) {
    presentedSheet = sheet
  }

  public func dismissSheet() {
    presentedSheet = nil
  }

  // MARK: - Persistence

  private func savePersistentState() {
    savePath()
    savePresentedSheet()
  }

  private func loadPersistentState() {
    loadPath()
    loadPresentedSheet()
  }

  // MARK: - Path Persistence

  private func savePath() {
    let currentPath = path
    let pathKey = pathKey

    Task.detached(priority: .background) {
      if let pathData = try? JSONEncoder().encode(currentPath) {
        UserDefaults.standard.set(pathData, forKey: pathKey)
      }
    }
  }

  private func loadPath() {
    if let pathData = UserDefaults.standard.data(forKey: pathKey),
       let decodedPath = try? JSONDecoder().decode([Destination].self, from: pathData)
    {
      path = decodedPath
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
    path = []
    presentedSheet = nil

    // Clear persisted data
    UserDefaults.standard.removeObject(forKey: pathKey)
    UserDefaults.standard.removeObject(forKey: presentedSheetKey)
  }
}
