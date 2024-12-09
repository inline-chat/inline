import SwiftUI
import UIKit

class BubbleColorManager {
  static let shared = BubbleColorManager()

  private let defaults = UserDefaults.standard
  private let colorKey = "selected_bubble_color"
  private let secondaryColorKey = "selected_bubble_secondary_color"
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

  let secondaryColors: [UIColor] = [
    .systemBlue.withAlphaComponent(0.3),
    .systemPurple.withAlphaComponent(0.3),
    .systemPink.withAlphaComponent(0.3),
    .systemGreen.withAlphaComponent(0.3),
    .systemIndigo.withAlphaComponent(0.3),
    .systemOrange.withAlphaComponent(0.3),
    .systemTeal.withAlphaComponent(0.3),
    .systemRed.withAlphaComponent(0.3),
    .systemGray6.withAlphaComponent(0.7),
  ]
  // Get the currently selected color, defaulting to system blue if none selected
  var selectedColor: UIColor {
    get {
      if let colorData = defaults.data(forKey: colorKey),
         let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: colorData)
      {
        return color
      }
      return .systemBlue // Default color
    }
    set {
      if let colorData = try? NSKeyedArchiver.archivedData(
        withRootObject: newValue, requiringSecureCoding: true)
      {
        defaults.set(colorData, forKey: colorKey)
      }
    }
  }

  var selectedSecondaryColor: UIColor {
    get {
      if let colorData = defaults.data(forKey: secondaryColorKey),
         let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: colorData)
      {
        return color
      }
      return .systemBlue // Default color
    }
    set {
      if let colorData = try? NSKeyedArchiver.archivedData(
        withRootObject: newValue, requiringSecureCoding: true)
      {
        defaults.set(colorData, forKey: secondaryColorKey)
      }
    }
  }

  // Save a new selected color
  func saveColor(_ color: UIColor) {
    selectedColor = color
  }

  func saveSecondaryColor(_ color: UIColor) {
    selectedSecondaryColor = color
  }

  // Reset to default color
  func resetToDefault() {
    defaults.removeObject(forKey: colorKey)
    defaults.removeObject(forKey: secondaryColorKey)
  }

  // Convert UIColor to Color for SwiftUI views
  var swiftUIColor: Color {
    Color(uiColor: selectedColor)
  }

  var swiftUIColorSecondary: Color {
    Color(uiColor: selectedSecondaryColor)
  }
}
