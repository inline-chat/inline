import UIKit

extension UIColor {
  convenience init?(hex: String) {
    let r: CGFloat
    let g: CGFloat
    let b: CGFloat

    let hexString = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex

    guard hexString.count == 6 else { return nil }

    let scanner = Scanner(string: hexString)
    var hexNumber: UInt64 = 0

    guard scanner.scanHexInt64(&hexNumber) else { return nil }

    r = CGFloat((hexNumber & 0xFF_0000) >> 16) / 255
    g = CGFloat((hexNumber & 0x00_FF00) >> 8) / 255
    b = CGFloat(hexNumber & 0x00_00FF) / 255

    self.init(red: r, green: g, blue: b, alpha: 1.0)
  }

  static func dynamic(light: String, dark: String) -> UIColor {
    UIColor { trait in
      if trait.userInterfaceStyle == .dark {
        UIColor(hex: dark) ?? .clear
      } else {
        UIColor(hex: light) ?? .clear
      }
    }
  }

  static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
    UIColor { trait in
      trait.userInterfaceStyle == .dark ? dark : light
    }
  }
}
