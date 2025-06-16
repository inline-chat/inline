import SwiftUI
import UIKit

protocol ThemeConfig {
  var backgroundColor: UIColor { get }
  var accent: UIColor { get }

  var bubbleBackground: UIColor { get }
  var incomingBubbleBackground: UIColor { get }

  // only for incoming messages for now
  var primaryTextColor: UIColor? { get }
  var secondaryTextColor: UIColor? { get }

  var reactionOutgoingPrimary: UIColor? { get }
  var reactionOutgoingSecoundry: UIColor? { get }

  var reactionIncomingPrimary: UIColor? { get }
  var reactionIncomingSecoundry: UIColor? { get }

  
  var id: String { get }
  var name: String { get }
}

class ThemeManager: ObservableObject {
  static let shared = ThemeManager()

  static let themes: [ThemeConfig] = [
    Default(),
    Lavender(),
    PeonyPink(),
    Orchid()
  ]

  private let defaults = UserDefaults.standard
  private let currentThemeKey = "selected_theme_id"

  @Published var selected: ThemeConfig {
    didSet {
      saveCurrentTheme()
    }
  }

  init() {
    if let savedThemeID = defaults.string(forKey: currentThemeKey),
       let savedTheme = Self.findTheme(withID: savedThemeID)
    {
      selected = savedTheme
    } else {
      selected = Default()
    }
  }

  private func saveCurrentTheme() {
    defaults.set(selected.id, forKey: currentThemeKey)
  }

  func switchToTheme(_ theme: ThemeConfig) {
    selected = theme
  }

  func switchToTheme(withID id: String) {
    if let theme = Self.findTheme(withID: id) {
      selected = theme
    }
  }

  func resetToDefaultTheme() {
    selected = Default()
  }

  // MARK: - Helper Methods

  static func findTheme(withID id: String) -> ThemeConfig? {
    return themes.first { $0.id == id }
  }
}
