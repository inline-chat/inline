// Core Graphics adaptation of SwiftMath's MIT MTColor helper; see NOTICE.md.
import Foundation
import CoreGraphics

struct MTColor {
  let cgColor: CGColor
  static var blue: MTColor { .init(cgColor: CGColor(red: 0, green: 0, blue: 1, alpha: 1)) }

  init(cgColor: CGColor) { self.cgColor = cgColor }

  init?(fromString source: String) {
    let rgb: UInt32
    if source.hasPrefix("#") {
      let hex = source.dropFirst()
      guard hex.utf8.count == 6, let parsed = UInt32(hex, radix: 16) else { return nil }
      rgb = parsed
    } else {
      guard let named = Self.namedColors[source.lowercased()] else { return nil }
      rgb = named
    }
    cgColor = CGColor(red: CGFloat((rgb >> 16) & 255) / 255,
                      green: CGFloat((rgb >> 8) & 255) / 255,
                      blue: CGFloat(rgb & 255) / 255, alpha: 1)
  }

  private static let namedColors: [String: UInt32] = [
    "black": 0x000000, "white": 0xffffff, "red": 0xff0000,
    "green": 0x00ff00, "blue": 0x0000ff, "cyan": 0x00ffff,
    "magenta": 0xff00ff, "yellow": 0xffff00, "gray": 0x808080,
    "darkgray": 0x404040, "lightgray": 0xbfbfbf, "brown": 0xbf8040,
    "orange": 0xff8000, "pink": 0xffbfbf, "purple": 0xbf0040,
    "teal": 0x008080, "violet": 0x800080,
  ]
}
