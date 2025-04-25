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
          r = CGFloat((hexNumber & 0xFF_0000) >> 16) / 255
          g = CGFloat((hexNumber & 0x00_FF00) >> 8) / 255
          b = CGFloat(hexNumber & 0x00_00FF) / 255

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
    UIColor(hex: "#52A5FF")!,
    UIColor(hex: "#2D93FF")!,
    UIColor(hex: "#FF82B8")!,
    UIColor(hex: "#CF7DFF")!,
    UIColor(hex: "#FF946D")!,
    UIColor(hex: "#55CA76")!,
    UIColor(hex: "#4DAEAD")!,
    UIColor(hex: "#6570FF")!,
    UIColor(hex: "#826FFF")!,
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
        withRootObject: newValue, requiringSecureCoding: true
      ) {
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

  var secondaryColor: UIColor {
    UIColor(dynamicProvider: { trait in
      if trait.userInterfaceStyle == .dark {
        UIColor(hex: "#27262B")!
      } else {
        UIColor(hex: "#F2F2F2")!
      }
    })
  }

  var gray1: UIColor {
    UIColor(dynamicProvider: { trait in
      if trait.userInterfaceStyle == .dark {
        UIColor(hex: "#3A393E")!
      } else {
        UIColor(hex: "#E6E6E6")!
      }
    })
  }
  
  var reactionItemColor: UIColor {
    UIColor(dynamicProvider: { trait in
      if trait.userInterfaceStyle == .dark {
        UIColor(hex: "#121212")!
      } else {
        UIColor(hex: "#FFFFFF")!
      }
    })
  }
}
