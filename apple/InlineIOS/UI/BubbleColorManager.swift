import SwiftUI
import UIKit

class BubbleColorManager {
  static let shared = BubbleColorManager()

  private let defaults = UserDefaults.standard
  private let colorKey = "selected_bubble_color"

  // Default color palette
  let availableColors: [UIColor] = [
    .systemBlue,
    .systemPurple,
    .systemPink,
    .systemGreen,
    .systemIndigo,
    .systemOrange,
    .systemTeal,
    .systemRed,
  ]

  // Get the currently selected color, defaulting to system blue if none selected
  var selectedColor: UIColor {
    get {
      if let colorData = defaults.data(forKey: colorKey),
        let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: colorData)
      {
        return color
      }
      return .systemBlue  // Default color
    }
    set {
      if let colorData = try? NSKeyedArchiver.archivedData(
        withRootObject: newValue, requiringSecureCoding: true)
      {
        defaults.set(colorData, forKey: colorKey)
      }
    }
  }

  // Save a new selected color
  func saveColor(_ color: UIColor) {
    selectedColor = color
  }

  // Reset to default color
  func resetToDefault() {
    defaults.removeObject(forKey: colorKey)
  }

  // Convert UIColor to Color for SwiftUI views
  var swiftUIColor: Color {
    Color(uiColor: selectedColor)
  }
}
