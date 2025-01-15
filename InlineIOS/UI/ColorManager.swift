import SwiftUI
import UIKit

extension UIColor {
  convenience init?(hex: String) {
    let r: CGFloat
    let g: CGFloat
    let b: CGFloat

    if hex.hasPrefix("#") {
      let start = hex.index(hex.startIndex, offsetBy: 1)
      let hexColor = String(hex[start...])

      if hexColor.count == 6 {
        let scanner = Scanner(string: hexColor)
        var hexNumber: UInt64 = 0

        if scanner.scanHexInt64(&hexNumber) {
          r = CGFloat((hexNumber & 0xff0000) >> 16) / 255
          g = CGFloat((hexNumber & 0x00ff00) >> 8) / 255
          b = CGFloat(hexNumber & 0x0000ff) / 255

          self.init(red: r, green: g, blue: b, alpha: 1.0)
          return
        }
      }
    }
    return nil
  }
}

class ColorManager {
  static let shared = ColorManager()

  private let defaults = UserDefaults.standard
  private let colorKey = "selected_bubble_color"
  private let secondaryColorKey = "selected_bubble_secondary_color"
  // Default color palette
  let availableColors: [UIColor] = [
    UIColor(hex: "#2F8AFA")!,
    UIColor(hex: "#AE4DF2")!,
    UIColor(hex: "#F776B3")!,
    UIColor(hex: "#2BC738")!,
    .systemIndigo,
    UIColor(hex: "#FF6449")!,
    .systemTeal,
    UIColor(hex: "#F34747")!,
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

  // Save a new selected color
  func saveColor(_ color: UIColor) {
    selectedColor = color
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
}
