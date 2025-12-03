import SwiftUI
import UIKit

// MARK: - Color Palette

enum ColorPalette {
  static let availableAccentColors: [UIColor] = [
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
}

// MARK: - Legacy Color Manager

class ColorManager {
  static let shared = ColorManager()

  let availableColors: [UIColor] = ColorPalette.availableAccentColors

  var selectedColor: UIColor {
    ThemeStore.shared.colors.accent
  }

  var swiftUIColor: Color {
    ThemeStore.shared.colors.accentColor
  }

  var secondaryColor: UIColor {
    ThemeStore.shared.colors.bubbleIncoming
  }

  var gray1: UIColor {
    .dynamic(light: "#E6E6E6", dark: "#3A393E")
  }

  var reactionItemColor: UIColor {
    .dynamic(light: "#FFFFFF", dark: "#121212")
  }
}
