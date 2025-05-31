import SwiftUI
import UIKit

protocol ThemeConfig {
  var backgroundColor: UIColor { get }
  var accent: UIColor { get }

  var deleteAction: UIColor? { get }
  var toastSuccess: UIColor? { get }
  var toastFailed: UIColor? { get }
  var toastInfo: UIColor? { get }

  var bubbleBackground: UIColor { get }
  var incomingBubbleBackground: UIColor { get }

  // only for incoming messages for now
  var primaryTextColor: UIColor? { get }
  var secondaryTextColor: UIColor? { get }

  var id: String { get }
  var name: String { get }
}

class ThemeManager: ObservableObject {
  static let shared = ThemeManager()

  static let themes: [ThemeConfig] = [
    Default(),
    Lavender(),
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

// MARK: - UIAction Extensions

extension UIAction {
  /// Creates a delete action with theme-based color if available, otherwise uses red
  static func createDeleteAction(title: String = "Delete", handler: @escaping UIActionHandler) -> UIAction {
    let deleteColor = ThemeManager.shared.selected.deleteAction ?? .systemRed

    // If we have a custom delete color, create an action without destructive attribute
    // and use attributed title for color
    if let customColor = ThemeManager.shared.selected.deleteAction {
      let attributedTitle = NSAttributedString(
        string: title,
        attributes: [.foregroundColor: customColor]
      )

      let action = UIAction(
        title: title,
        image: UIImage(systemName: "trash")?.withTintColor(customColor, renderingMode: .alwaysOriginal)
      ) { action in
        handler(action)
      }

      // Set the attributed title using setValue
      action.setValue(attributedTitle, forKey: "attributedTitle")

      return action
    } else {
      // Use default destructive styling for red
      return UIAction(
        title: title,
        image: UIImage(systemName: "trash"),
        attributes: .destructive,
        handler: handler
      )
    }
  }
}

// MARK: - SwiftUI Extensions

extension View {
  /// Applies theme-aware destructive styling to a button
  func themeDestructive() -> some View {
    if let deleteColor = ThemeManager.shared.selected.deleteAction {
      return foregroundColor(Color(deleteColor))
    } else {
      return foregroundColor(.red)
    }
  }
}

// MARK: - SwiftUI Button Helpers

struct ThemeDestructiveButton<Label: View>: View {
  let action: () -> Void
  let label: () -> Label

  init(action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
    self.action = action
    self.label = label
  }

  var body: some View {
    Button(action: action) {
      label()
    }
    .themeDestructive()
  }
}
