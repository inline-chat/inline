import SwiftUI
import UIKit

protocol ThemeConfig {
  var backgroundColor: UIColor { get }
  var accent: UIColor { get }

  var bubbleBackground: UIColor { get }
  var incomingBubbleBackground: UIColor { get }
  var failedBubbleBackground: UIColor { get }

  // only for incoming messages for now
  var primaryTextColor: UIColor? { get }
  var secondaryTextColor: UIColor? { get }

  var reactionOutgoingPrimary: UIColor? { get }
  var reactionOutgoingSecoundry: UIColor? { get }

  var reactionIncomingPrimary: UIColor? { get }
  var reactionIncomingSecoundry: UIColor? { get }

  var documentIconBackground: UIColor? { get }

  // New Catppuccin Mocha colors for comprehensive theming
  var listRowBackground: UIColor? { get }
  var listSeparatorColor: UIColor? { get }
  var navigationBarBackground: UIColor? { get }
  var toolbarBackground: UIColor? { get }
  var surfaceBackground: UIColor? { get }
  var surfaceSecondary: UIColor? { get }
  var textPrimary: UIColor? { get }
  var textSecondary: UIColor? { get }
  var textTertiary: UIColor? { get }
  var borderColor: UIColor? { get }
  var overlayBackground: UIColor? { get }
  var cardBackground: UIColor? { get }
  var searchBarBackground: UIColor? { get }
  var buttonBackground: UIColor? { get }
  var buttonSecondaryBackground: UIColor? { get }
  var sheetTintColor: UIColor? { get }
  var logoutRed: UIColor { get }

  var id: String { get }
  var name: String { get }
}

class ThemeManager: ObservableObject {
  static let shared = ThemeManager()

  static let themes: [ThemeConfig] = [
    Default(),
    CatppuccinMocha(),
    PeonyPink(),
    Orchid(),
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
    themes.first { $0.id == id }
  }
}

// MARK: - SwiftUI Color Extensions

extension ThemeManager {
  var surfaceBackgroundColor: Color {
    Color(selected.surfaceBackground ?? .secondarySystemBackground)
  }

  var surfaceSecondaryColor: Color {
    Color(selected.surfaceSecondary ?? .tertiarySystemBackground)
  }

  var textPrimaryColor: Color {
    Color(selected.textPrimary ?? .label)
  }

  var textSecondaryColor: Color {
    Color(selected.textSecondary ?? .secondaryLabel)
  }

  var textTertiaryColor: Color {
    Color(selected.textTertiary ?? .tertiaryLabel)
  }

  var borderColor: Color {
    Color(selected.borderColor ?? .separator)
  }

  var overlayBackgroundColor: Color {
    Color(selected.overlayBackground ?? .systemGray)
  }

  var cardBackgroundColor: Color {
    Color(selected.cardBackground ?? .secondarySystemBackground)
  }

  var searchBarBackgroundColor: Color {
    Color(selected.searchBarBackground ?? .systemGray6)
  }

  var buttonBackgroundColor: Color {
    Color(selected.buttonBackground ?? selected.accent)
  }

  var buttonSecondaryBackgroundColor: Color {
    Color(selected.buttonSecondaryBackground ?? .systemGray2)
  }

  var accentColor: Color {
    Color(selected.accent)
  }

  var sheetTintColor: Color {
    Color(selected.sheetTintColor ?? selected.accent)
  }

  var logoutRedColor: Color {
    Color(selected.logoutRed)
  }
}
