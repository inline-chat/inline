import Observation
import SwiftUI

@Observable
final class ThemeStore {
  static let shared = ThemeStore()

  private let userDefaults = UserDefaults.standard
  private let themeKey = "selected_theme_id"

  private(set) var current: AppTheme

  private init() {
    if let savedId = UserDefaults.standard.string(forKey: themeKey),
       let savedTheme = AppTheme.find(byId: savedId)
    {
      current = savedTheme
    } else {
      current = .default
    }
  }

  func select(_ theme: AppTheme) {
    current = theme
    userDefaults.set(theme.id, forKey: themeKey)
  }

  func select(byId id: String) {
    guard let theme = AppTheme.find(byId: id) else { return }
    select(theme)
  }

  func reset() {
    select(.default)
  }
}

// MARK: - Convenience Accessors

extension ThemeStore {
  var colors: ThemeColors {
    current.colors
  }
}
