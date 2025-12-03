import SwiftUI
import UIKit

// MARK: - Legacy Compatibility Layer
// This provides backward compatibility with existing code while migrating to the new theme system.
// New code should use ThemeStore.shared and @Environment(\.theme) directly.

protocol ThemeConfig {
  var backgroundColor: UIColor { get }
  var accent: UIColor { get }

  var bubbleBackground: UIColor { get }
  var incomingBubbleBackground: UIColor { get }
  var failedBubbleBackground: UIColor { get }

  var primaryTextColor: UIColor? { get }
  var secondaryTextColor: UIColor? { get }

  var reactionOutgoingPrimary: UIColor? { get }
  var reactionOutgoingSecoundry: UIColor? { get }

  var reactionIncomingPrimary: UIColor? { get }
  var reactionIncomingSecoundry: UIColor? { get }

  var documentIconBackground: UIColor? { get }

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

// MARK: - AppTheme to ThemeConfig Adapter

extension AppTheme: ThemeConfig {
  var backgroundColor: UIColor { colors.background }
  var accent: UIColor { colors.accent }
  var bubbleBackground: UIColor { colors.bubbleOutgoing }
  var incomingBubbleBackground: UIColor { colors.bubbleIncoming }
  var failedBubbleBackground: UIColor { colors.bubbleFailed }

  var primaryTextColor: UIColor? { colors.textPrimary }
  var secondaryTextColor: UIColor? { colors.textSecondary }

  var reactionOutgoingPrimary: UIColor? { colors.reactionOutgoingPrimary }
  var reactionOutgoingSecoundry: UIColor? { colors.reactionOutgoingSecondary }
  var reactionIncomingPrimary: UIColor? { colors.reactionIncomingPrimary }
  var reactionIncomingSecoundry: UIColor? { colors.reactionIncomingSecondary }

  var documentIconBackground: UIColor? { colors.documentIconBackground }

  var listRowBackground: UIColor? { colors.background }
  var listSeparatorColor: UIColor? { colors.separator }
  var navigationBarBackground: UIColor? { colors.navigationBar }
  var toolbarBackground: UIColor? { colors.toolbar }
  var surfaceBackground: UIColor? { colors.surface }
  var surfaceSecondary: UIColor? { colors.surfaceSecondary }
  var textPrimary: UIColor? { colors.textPrimary }
  var textSecondary: UIColor? { colors.textSecondary }
  var textTertiary: UIColor? { colors.textTertiary }
  var borderColor: UIColor? { colors.border }
  var overlayBackground: UIColor? { colors.overlay }
  var cardBackground: UIColor? { colors.card }
  var searchBarBackground: UIColor? { colors.searchBar }
  var buttonBackground: UIColor? { colors.buttonPrimary }
  var buttonSecondaryBackground: UIColor? { colors.buttonSecondary }
  var sheetTintColor: UIColor? { colors.accent }
  var logoutRed: UIColor { colors.destructive }
}

// MARK: - ThemeManager (Legacy Wrapper)

class ThemeManager: ObservableObject {
  static let shared = ThemeManager()

  static var themes: [ThemeConfig] {
    AppTheme.allThemes
  }

  @Published var selected: ThemeConfig

  private init() {
    selected = ThemeStore.shared.current
  }

  func switchToTheme(_ theme: ThemeConfig) {
    if let appTheme = theme as? AppTheme {
      ThemeStore.shared.select(appTheme)
      selected = appTheme
    }
  }

  func switchToTheme(withID id: String) {
    if let theme = Self.findTheme(withID: id) {
      switchToTheme(theme)
    }
  }

  func resetToDefaultTheme() {
    ThemeStore.shared.reset()
    selected = ThemeStore.shared.current
  }

  static func findTheme(withID id: String) -> ThemeConfig? {
    AppTheme.find(byId: id)
  }
}

// MARK: - SwiftUI Color Extensions (Legacy)

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
