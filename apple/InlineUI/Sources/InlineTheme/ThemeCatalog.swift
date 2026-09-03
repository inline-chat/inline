import Foundation

public enum AppThemePreset: String, CaseIterable, Codable, Identifiable, Sendable {
  case system
  case pink
  case sunset
  case midnight
  case ash
  case flexoki
  case pastel
  case neonNoir = "neon-noir"

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .system: "System"
    case .pink: "Pink"
    case .sunset: "Sunset"
    case .midnight: "Midnight"
    case .ash: "Ash"
    case .flexoki: "Flexoki"
    case .pastel: "Pastel"
    case .neonNoir: "Neon Noir"
    }
  }

  public init(migratingLegacyIOSIdentifier identifier: String?) {
    if let identifier, let preset = Self(rawValue: identifier) {
      self = preset
      return
    }

    switch identifier {
    case "CatppuccinMocha", "PeonyPink", "Orchid":
      self = .pastel
    default:
      self = .system
    }
  }
}

public enum ThemeAppearanceVariant: String, CaseIterable, Codable, Identifiable, Sendable {
  case light
  case dark

  public var id: String { rawValue }
  public var title: String { self == .light ? "Light" : "Dark" }
}

public enum ThemeColorRole: String, CaseIterable, Codable, Identifiable, Sendable {
  case accent
  case prominent
  case bubble
  case background

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .accent: "Accent"
    case .prominent: "Prominent"
    case .bubble: "Outgoing Bubble"
    case .background: "Background"
    }
  }
}

public enum ThemeSeedRole: String, CaseIterable, Codable, Identifiable, Sendable {
  case primary
  case canvas

  public var id: String { rawValue }
  public var title: String { self == .primary ? "Primary" : "Window" }
}

public struct ThemeColorValue: Codable, Equatable, Sendable {
  public let red: Double
  public let green: Double
  public let blue: Double
  public let alpha: Double

  public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
    self.red = red.clamped(to: 0 ... 1)
    self.green = green.clamped(to: 0 ... 1)
    self.blue = blue.clamped(to: 0 ... 1)
    self.alpha = alpha.clamped(to: 0 ... 1)
  }

  public init(rgb: UInt32, alpha: Double = 1) {
    self.init(
      red: Double((rgb >> 16) & 0xFF) / 255,
      green: Double((rgb >> 8) & 0xFF) / 255,
      blue: Double(rgb & 0xFF) / 255,
      alpha: alpha
    )
  }

  public init?(hexRGB: String) {
    let value = hexRGB.trimmingCharacters(in: .whitespacesAndNewlines)
    let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
    guard digits.count == 6, let rgb = UInt32(digits, radix: 16) else { return nil }
    self.init(rgb: rgb)
  }

  public var hexRGB: String {
    String(
      format: "#%02X%02X%02X",
      Int((red * 255).rounded()),
      Int((green * 255).rounded()),
      Int((blue * 255).rounded())
    )
  }
}

public struct ThemePalette: Codable, Equatable, Sendable {
  public var primary: ThemeColorValue
  public var canvas: ThemeColorValue

  public init(primary: ThemeColorValue, canvas: ThemeColorValue) {
    self.primary = primary
    self.canvas = canvas
  }

  public var accent: ThemeColorValue {
    get { primary }
    set { primary = newValue }
  }

  public var prominent: ThemeColorValue {
    get { primary }
    set { primary = newValue }
  }

  public var bubble: ThemeColorValue {
    get { primary }
    set { primary = newValue }
  }

  public var background: ThemeColorValue {
    get { canvas }
    set { canvas = newValue }
  }

  public subscript(seed role: ThemeSeedRole) -> ThemeColorValue {
    get { role == .primary ? primary : canvas }
    set {
      if role == .primary { primary = newValue } else { canvas = newValue }
    }
  }

  public subscript(role: ThemeColorRole) -> ThemeColorValue {
    get {
      switch role {
      case .accent: accent
      case .prominent: prominent
      case .bubble: bubble
      case .background: background
      }
    }
    set {
      switch role {
      case .accent: accent = newValue
      case .prominent: prominent = newValue
      case .bubble: bubble = newValue
      case .background: background = newValue
      }
    }
  }
}

public struct ThemeBubbleLightingAlphas: Equatable, Sendable {
  public let top: Double
  public let bottom: Double

  public init(top: Double, bottom: Double) {
    self.top = top
    self.bottom = bottom
  }
}

public struct ThemeBubbleGradientVector: Equatable, Sendable {
  public let startY: Double
  public let endY: Double

  public init(startY: Double, endY: Double) {
    self.startY = startY
    self.endY = endY
  }
}

public enum ThemeCatalog {
  public static let messageBubbleGradientTopOverlayAlpha = 0.26
  public static let messageBubbleGradientBottomOverlayAlpha = 0.02

  public static func palette(
    preset: AppThemePreset,
    variant: ThemeAppearanceVariant,
    systemCanvas: ThemeColorValue
  ) -> ThemePalette {
    switch (preset, variant) {
    case (.system, .light):
      ThemePalette(primary: .init(rgb: 0x00A7F8), canvas: systemCanvas)
    case (.system, .dark):
      ThemePalette(primary: .init(rgb: 0x0A84FF), canvas: systemCanvas)
    case (.pink, .light):
      ThemePalette(primary: .init(rgb: 0xFD4F7E), canvas: .init(rgb: 0xFFF5F7))
    case (.pink, .dark):
      ThemePalette(primary: .init(rgb: 0xFD4F7E), canvas: .init(rgb: 0x241116))
    case (.sunset, .light):
      ThemePalette(primary: .init(rgb: 0xC94D24), canvas: .init(rgb: 0xFFF5F0))
    case (.sunset, .dark):
      ThemePalette(primary: .init(rgb: 0xC94D24), canvas: .init(rgb: 0x2A1A15))
    case (.midnight, .light):
      ThemePalette(primary: .init(rgb: 0x0969DA), canvas: .init(rgb: 0xFFFFFF))
    case (.midnight, .dark):
      ThemePalette(primary: .init(rgb: 0x0969DA), canvas: .init(rgb: 0x0D1117))
    case (.ash, .light):
      ThemePalette(primary: .init(rgb: 0x44494D), canvas: .init(rgb: 0xFFFFFF))
    case (.ash, .dark):
      ThemePalette(primary: .init(rgb: 0x44494D), canvas: .init(rgb: 0x151516))
    case (.flexoki, .light):
      ThemePalette(primary: .init(rgb: 0x205EA6), canvas: .init(rgb: 0xFFFCF0))
    case (.flexoki, .dark):
      ThemePalette(primary: .init(rgb: 0x205EA6), canvas: .init(rgb: 0x100F0F))
    case (.pastel, .light):
      ThemePalette(primary: .init(rgb: 0x7D57C1), canvas: .init(rgb: 0xE2DAF1))
    case (.pastel, .dark):
      ThemePalette(primary: .init(rgb: 0x7D57C1), canvas: .init(rgb: 0x292D3E))
    case (.neonNoir, .light):
      ThemePalette(primary: .init(rgb: 0x623BE2), canvas: .init(rgb: 0xF7F7F7))
    case (.neonNoir, .dark):
      ThemePalette(primary: .init(rgb: 0x623BE2), canvas: .init(rgb: 0x080808))
    }
  }

  public static func secondaryBubble(
    preset: AppThemePreset,
    variant: ThemeAppearanceVariant
  ) -> ThemeColorValue {
    if preset == .system, variant == .light {
      return .init(rgb: 0xECECEC)
    }
    return variant == .light ? .init(rgb: 0xEAEAEA) : .init(rgb: 0x2E2E2E)
  }

  public static func messageBubbleGradientOverlayAlphas(
    variant: ThemeAppearanceVariant,
    outgoing: Bool
  ) -> ThemeBubbleLightingAlphas {
    guard variant == .dark else {
      return .init(
        top: messageBubbleGradientTopOverlayAlpha,
        bottom: messageBubbleGradientBottomOverlayAlpha
      )
    }

    let strength = outgoing ? 0.6 : 0.4
    return .init(
      top: messageBubbleGradientTopOverlayAlpha * strength,
      bottom: messageBubbleGradientBottomOverlayAlpha * strength
    )
  }

  public static func messageBubbleGradientOverlayAlpha(
    atViewportFraction fraction: Double,
    variant: ThemeAppearanceVariant,
    outgoing: Bool
  ) -> Double {
    let progress = fraction.clamped(to: 0 ... 1)
    let alphas = messageBubbleGradientOverlayAlphas(variant: variant, outgoing: outgoing)
    return alphas.top + (alphas.bottom - alphas.top) * progress
  }

  public static func bubbleGradientVector(
    bubbleMinY: Double,
    bubbleHeight: Double,
    viewportMinY: Double,
    viewportHeight: Double
  ) -> ThemeBubbleGradientVector? {
    guard bubbleMinY.isFinite, bubbleHeight.isFinite, viewportMinY.isFinite,
          viewportHeight.isFinite, bubbleHeight > 1, viewportHeight > 1
    else { return nil }

    let distanceFromViewportTop = bubbleMinY - viewportMinY
    return .init(
      startY: -distanceFromViewportTop / bubbleHeight,
      endY: (viewportHeight - distanceFromViewportTop) / bubbleHeight
    )
  }
}

private extension Double {
  func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
