import InlineKit
import SwiftUI

@MainActor
public struct InitialsCircle: View, Equatable {
  let name: String
  let size: CGFloat
  let symbol: String?

  public nonisolated static func == (lhs: InitialsCircle, rhs: InitialsCircle) -> Bool {
    lhs.name == rhs.name &&
      lhs.size == rhs.size
  }

  @Environment(\.colorScheme) private var colorScheme

  @MainActor
  public enum ColorPalette {
    @MainActor

    static let colors: [Color] = [
      .pink.adjustLuminosity(by: -0.1),
      .orange,
      .purple,
      .yellow.adjustLuminosity(by: -0.1),
      .teal,
      .blue,
      .teal,
      .green,
      .primary,
      .red,
      .indigo,
      .mint,
      .cyan,
//      .gray,
//      .brown,
    ]

    public static func color(for name: String) -> Color {
      // let hash = name.hashValue
      let hash = name.utf8.reduce(0) { $0 + Int($1) }
      return colors[abs(hash) % colors.count]
    }
  }

  private var initials: String {
    name.first.map(String.init)?.uppercased() ?? ""
  }

  private var backgroundColor: Color {
    let baseColor = ColorPalette.color(for: name)
    return colorScheme == .dark
      ? baseColor.adjustLuminosity(by: -0.1)
      : baseColor.adjustLuminosity(by: 0)
  }

  private var foregroundColor: Color {
    .white
  }

  private var backgroundGradient: LinearGradient {
    LinearGradient(
      colors: [
        backgroundColor.adjustLuminosity(by: 0.2),
        backgroundColor.adjustLuminosity(by: 0),
      ],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  public init(name: String, size: CGFloat = 32, symbol: String? = nil) {
    self.name = name
    self.size = size
    self.symbol = symbol
  }

  public var body: some View {
    Circle()
      .fill(backgroundGradient)
      .overlay(
        Circle()
          .stroke(
            backgroundColor.adjustLuminosity(by: -0.4).opacity(0.1),
            lineWidth: 0.5
          )
      )
      .overlay {
        if let symbol {
          Image(systemName: symbol)
            .foregroundColor(foregroundColor.opacity(1.0))
            .font(.system(size: size * 0.35, weight: .regular))
        } else {
          Text(initials)
            .foregroundColor(foregroundColor.opacity(1.0))
            .font(.system(size: size * 0.55, weight: .regular))
            .lineLimit(1)
        }
      }
      .frame(width: size, height: size)
      .fixedSize()

    // Looks better without these
//      .drawingGroup(opaque: true)
//      .clipShape(Circle())
  }
}

// MARK: - Color Extensions

private extension Color {
  init(hex: String) {
    let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var int: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&int)
    let a: UInt64
    let r: UInt64
    let g: UInt64
    let b: UInt64
    switch hex.count {
      case 3: // RGB (12-bit)
        (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
      case 6: // RGB (24-bit)
        (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
      case 8: // ARGB (32-bit)
        (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
      default:
        (a, r, g, b) = (255, 0, 0, 0)
    }
    self.init(
      .sRGB,
      red: Double(r) / 255,
      green: Double(g) / 255,
      blue: Double(b) / 255,
      opacity: Double(a) / 255
    )
  }

  func adjustBrightness(by amount: Double) -> Color {
    #if os(iOS)
    guard let components = UIColor(self).cgColor.components,
          components.count >= 3
    else { return self }

    let r = components[0]
    let g = components[1]
    let b = components[2]
    let alpha = components.count >= 4 ? components[3] : 1.0

    return Color(
      .sRGB,
      red: min(r + amount, 1.0),
      green: min(g + amount, 1.0),
      blue: min(b + amount, 1.0),
      opacity: alpha
    )
    #else
    guard let components = NSColor(self).cgColor.components,
          components.count >= 3
    else { return self }

    let r = components[0]
    let g = components[1]
    let b = components[2]
    let alpha = components.count >= 4 ? components[3] : 1.0

    return Color(
      .sRGB,
      red: min(r + amount, 1.0),
      green: min(g + amount, 1.0),
      blue: min(b + amount, 1.0),
      opacity: alpha
    )
    #endif
  }
}

private extension Color {
  // Use a proper cache key that includes all relevant components
  private struct ColorAdjustmentKey: Hashable {
    let colorHash: Int
    let amount: Double

    // Round amount to reduce cache variations
    init(color: Color, amount: Double) {
      // Create a consistent hash for the color
      #if os(iOS)
      colorHash = UIColor(color).hashValue
      #else
      colorHash = NSColor(color).hashValue
      #endif
      // Round to 3 decimal places to prevent floating-point precision issues
      self.amount = (amount * 1_000).rounded() / 1_000
    }
  }

  // Use NSCache instead of Dictionary for better memory management
  @MainActor private static let adjustmentCache: NSCache<NSString, AnyObject> = {
    let cache = NSCache<NSString, AnyObject>()
    cache.countLimit = 200 // Limit cache size
    return cache
  }()

  @MainActor public func adjustLuminosity(by amount: Double) -> Color {
    let key = ColorAdjustmentKey(color: self, amount: amount)
    let cacheKey = NSString(string: "\(key.colorHash):\(key.amount)")
    // Try to get from cache
    #if os(iOS)
    if let cachedColor = Self.adjustmentCache.object(forKey: cacheKey) as? UIColor {
      return Color(uiColor: cachedColor)
    }
    #else
    if let cachedColor = Self.adjustmentCache.object(forKey: cacheKey) as? NSColor {
      return Color(nsColor: cachedColor)
    }
    #endif

    // If not in cache, compute new color
    let adjustedColor = performLuminosityAdjustment(by: amount)

    // Store in cache
    #if os(iOS)
    Self.adjustmentCache.setObject(UIColor(adjustedColor), forKey: cacheKey)
    #else
    Self.adjustmentCache.setObject(NSColor(adjustedColor), forKey: cacheKey)
    #endif

    return adjustedColor
  }

  private func performLuminosityAdjustment(by amount: Double) -> Color {
    #if os(iOS)
    let uiColor = UIColor(self)
    guard let rgbColor = uiColor.cgColor.converted(
      to: CGColorSpace(name: CGColorSpace.sRGB)!,
      intent: .defaultIntent,
      options: nil
    ) else { return self }
    #else
    let nsColor = NSColor(self)
    guard let rgbColor = nsColor.cgColor.converted(
      to: CGColorSpace(name: CGColorSpace.sRGB)!,
      intent: .defaultIntent,
      options: nil
    ) else { return self }
    #endif

    let components = rgbColor.components ?? []
    guard components.count >= 3 else { return self }

    let r = components[0]
    let g = components[1]
    let b = components[2]
    let a = components.count >= 4 ? components[3] : 1.0

    let maxValue = max(r, max(g, b))
    let minValue = min(r, min(g, b))
    let delta = maxValue - minValue

    var h: CGFloat = 0
    var s: CGFloat = 0
    var l = (maxValue + minValue) / 2

    if delta != 0 {
      s = l < 0.5 ? delta / (maxValue + minValue) : delta / (2 - maxValue - minValue)

      if maxValue == r {
        h = (g - b) / delta + (g < b ? 6 : 0)
      } else if maxValue == g {
        h = (b - r) / delta + 2
      } else {
        h = (r - g) / delta + 4
      }

      h /= 6
    }

    l = max(0, min(1, l + CGFloat(amount)))

    func hueToRGB(_ p: CGFloat, _ q: CGFloat, _ t: CGFloat) -> CGFloat {
      var t = t
      if t < 0 { t += 1 }
      if t > 1 { t -= 1 }
      if t < 1 / 6 { return p + (q - p) * 6 * t }
      if t < 1 / 2 { return q }
      if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
      return p
    }

    let q = l < 0.5 ? l * (1 + s) : l + s - l * s
    let p = 2 * l - q

    let newR = hueToRGB(p, q, h + 1 / 3)
    let newG = hueToRGB(p, q, h)
    let newB = hueToRGB(p, q, h - 1 / 3)

    return Color(
      .sRGB,
      red: Double(max(0, min(1, newR))),
      green: Double(max(0, min(1, newG))),
      blue: Double(max(0, min(1, newB))),
      opacity: Double(a)
    )
  }
}

#Preview("Colors") {
  let s = 40.0

  ScrollView {
    LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 5), spacing: 20) {
      Group {
        // Original names
        Circle()
          .fill(InitialsCircle.ColorPalette.colors[0]).frame(width: s, height: s)
        Circle()
          .fill(InitialsCircle.ColorPalette.colors[1]).frame(width: s, height: s)
        Circle()
          .fill(InitialsCircle.ColorPalette.colors[2]).frame(width: s, height: s)
        Circle()
          .fill(InitialsCircle.ColorPalette.colors[3]).frame(width: s, height: s)
        Circle()
          .fill(InitialsCircle.ColorPalette.colors[4]).frame(width: s, height: s)
        Circle()
          .fill(InitialsCircle.ColorPalette.colors[5]).frame(width: s, height: s)
        Circle()
          .fill(InitialsCircle.ColorPalette.colors[6]).frame(width: s, height: s)
        Circle()
          .fill(InitialsCircle.ColorPalette.colors[7]).frame(width: s, height: s)
        Circle()
          .fill(InitialsCircle.ColorPalette.colors[8]).frame(width: s, height: s)
        Circle()
          .fill(InitialsCircle.ColorPalette.colors[9]).frame(width: s, height: s)
        Circle()
          .fill(InitialsCircle.ColorPalette.colors[10]).frame(width: s, height: s)
        Circle()
          .fill(InitialsCircle.ColorPalette.colors[11]).frame(width: s, height: s)
      }
    }
    .frame(width: 300, height: 300)
    .padding()
  }
}

#Preview("InitialsCircle Grid") {
  ScrollView {
    LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 4), spacing: 20) {
      Group {
        // Original names
        InitialsCircle(name: "John Doe", size: 60)
        InitialsCircle(name: "Alice Smith", size: 60)
        InitialsCircle(name: "Bob Johnson", size: 60)
        InitialsCircle(name: "Emma Davis", size: 60)
        InitialsCircle(name: "Michael Brown", size: 60)
        InitialsCircle(name: "Sarah Wilson", size: 60)
        InitialsCircle(name: "David Miller", size: 60)
        InitialsCircle(name: "Lisa Anderson", size: 60)

        // Tech Industry Names
        InitialsCircle(name: "Sam Altman", size: 40)
        InitialsCircle(name: "Elon Musk", size: 40)
        InitialsCircle(name: "Tim Cook", size: 40)
        InitialsCircle(name: "Sundar Pichai", size: 40)

        // International Names
        InitialsCircle(name: "田中 優紀", size: 24)
        InitialsCircle(name: "陈伟", size: 24)
        InitialsCircle(name: "Sofia Martinez", size: 24)

        // Farsi Names
        InitialsCircle(name: "دنا سهرابی", size: 24)
        InitialsCircle(name: "محمد رجبی", size: 24)

        // Arabic Names
        InitialsCircle(name: "فاطمة السيد", size: 32)
        InitialsCircle(name: "عمر الرشيد", size: 32)
        InitialsCircle(name: "ليلى محمود", size: 32)
        InitialsCircle(name: "كريم الحسن", size: 32)

        // Chinese Names
        InitialsCircle(name: "李伟", size: 32)
        InitialsCircle(name: "张敏", size: 32)
        InitialsCircle(name: "王小平", size: 32)
        InitialsCircle(name: "刘亦菲", size: 32)

        // Spanish Names
        InitialsCircle(name: "Isabella García", size: 32)
        InitialsCircle(name: "Miguel Rodríguez", size: 32)
        InitialsCircle(name: "Carmen López", size: 32)
        InitialsCircle(name: "José Hernández", size: 32)
      }
    }
    .frame(width: 300, height: 300)
    .padding()
  }
}
