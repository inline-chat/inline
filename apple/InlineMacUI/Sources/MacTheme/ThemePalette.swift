import AppKit
import Foundation

public enum AppThemePreset: String, CaseIterable, Codable, Identifiable, Sendable {
  case system
  case sunset
  case midnight
  case ash
  case flexoki
  case pastel
  case neonNoir = "neon-noir"

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .system:
      "System"
    case .sunset:
      "Sunset"
    case .midnight:
      "Midnight"
    case .ash:
      "Ash"
    case .flexoki:
      "Flexoki"
    case .pastel:
      "Pastel"
    case .neonNoir:
      "Neon Noir"
    }
  }
}

public enum ThemeAppearanceVariant: String, CaseIterable, Codable, Identifiable, Sendable {
  case light
  case dark

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .light:
      "Light"
    case .dark:
      "Dark"
    }
  }

  public init(appearance: NSAppearance) {
    self = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
  }

  public var nsAppearance: NSAppearance {
    guard let appearance = NSAppearance(named: self == .dark ? .darkAqua : .aqua) else {
      preconditionFailure("Built-in Aqua appearance is unavailable")
    }
    return appearance
  }
}

public enum SystemThemeAccent: String, CaseIterable, Codable, Identifiable, Sendable {
  case native
  case blue
  case purple
  case pink
  case orange
  case green

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .native:
      "Native"
    case .blue:
      "Blue"
    case .purple:
      "Purple"
    case .pink:
      "Pink"
    case .orange:
      "Orange"
    case .green:
      "Green"
    }
  }

  public func colorValue(appearance: NSAppearance) -> ThemeColorValue {
    let color: NSColor = switch self {
    case .native:
      .controlAccentColor
    case .blue:
      .systemBlue
    case .purple:
      .systemPurple
    case .pink:
      .systemPink
    case .orange:
      .systemOrange
    case .green:
      .systemGreen
    }
    return ThemeColorValue(nsColor: color, appearance: appearance)
  }
}

public enum ThemeColorRole: String, CaseIterable, Codable, Identifiable, Sendable {
  case accent
  case prominent
  case bubble
  case background

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .accent:
      "Accent"
    case .prominent:
      "Prominent"
    case .bubble:
      "Outgoing Bubble"
    case .background:
      "Background"
    }
  }
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
    guard digits.count == 6,
          let rgb = UInt32(digits, radix: 16)
    else { return nil }
    self.init(rgb: rgb)
  }

  public init(nsColor: NSColor, appearance: NSAppearance) {
    let color = nsColor.resolvedThemeColor(with: appearance)
    self.init(
      red: Double(color.redComponent),
      green: Double(color.greenComponent),
      blue: Double(color.blueComponent),
      alpha: Double(color.alphaComponent)
    )
  }

  public var nsColor: NSColor {
    NSColor(
      srgbRed: CGFloat(red),
      green: CGFloat(green),
      blue: CGFloat(blue),
      alpha: CGFloat(alpha)
    )
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
  public var accent: ThemeColorValue
  public var prominent: ThemeColorValue
  public var bubble: ThemeColorValue
  public var background: ThemeColorValue

  public init(
    accent: ThemeColorValue,
    prominent: ThemeColorValue,
    bubble: ThemeColorValue,
    background: ThemeColorValue
  ) {
    self.accent = accent
    self.prominent = prominent
    self.bubble = bubble
    self.background = background
  }

  public subscript(role: ThemeColorRole) -> ThemeColorValue {
    get {
      switch role {
      case .accent:
        accent
      case .prominent:
        prominent
      case .bubble:
        bubble
      case .background:
        background
      }
    }
    set {
      switch role {
      case .accent:
        accent = newValue
      case .prominent:
        prominent = newValue
      case .bubble:
        bubble = newValue
      case .background:
        background = newValue
      }
    }
  }
}

public enum ThemePreference {
  public static let selectedPresetKey = "macAppThemePreset"
  public static let selectedSystemAccentKey = "macAppThemeSystemAccent"

  public static func selectedPreset(userDefaults: UserDefaults = .standard) -> AppThemePreset {
    guard let rawValue = userDefaults.string(forKey: selectedPresetKey),
          let preset = AppThemePreset(rawValue: rawValue)
    else { return .system }
    return preset
  }

  public static func selectedSystemAccent(
    userDefaults: UserDefaults = .standard
  ) -> SystemThemeAccent {
    guard let rawValue = userDefaults.string(forKey: selectedSystemAccentKey),
          let accent = SystemThemeAccent(rawValue: rawValue)
    else { return .native }
    return accent
  }
}

public enum ThemePaletteOverrides {
  /// Kept stable so palettes adjusted with pre-import debug builds remain available.
  public static let storageKey = "macAppThemeDebugOverrides.v1"

  public static func hasOverrides(
    preset: AppThemePreset,
    userDefaults: UserDefaults = .standard
  ) -> Bool {
    customizedPresets(userDefaults: userDefaults).contains(preset)
  }

  public static func customizedPresets(
    userDefaults: UserDefaults = .standard
  ) -> Set<AppThemePreset> {
    let keys = storage(userDefaults: userDefaults).colors.keys
    return Set(AppThemePreset.allCases.filter { preset in
      if preset == .system {
        return ThemeAppearanceVariant.allCases.contains { variant in
          keys.contains(key(preset: preset, variant: variant, role: .bubble))
        }
      }
      return keys.contains { $0.hasPrefix("\(preset.rawValue).") }
    })
  }

  public static func applyingOverrides(
    to basePalette: ThemePalette,
    preset: AppThemePreset,
    variant: ThemeAppearanceVariant,
    userDefaults: UserDefaults = .standard
  ) -> ThemePalette {
    let colors = storage(userDefaults: userDefaults).colors
    var palette = basePalette
    for role in editableRoles(for: preset) {
      if let color = colors[key(preset: preset, variant: variant, role: role)] {
        palette[role] = color
      }
    }
    return palette
  }

  public static func setColor(
    _ color: ThemeColorValue,
    preset: AppThemePreset,
    variant: ThemeAppearanceVariant,
    role: ThemeColorRole,
    userDefaults: UserDefaults = .standard
  ) {
    guard editableRoles(for: preset).contains(role) else { return }
    var value = storage(userDefaults: userDefaults)
    value.colors[key(preset: preset, variant: variant, role: role)] = color
    save(value, userDefaults: userDefaults)
  }

  public static func reset(
    preset: AppThemePreset,
    variant: ThemeAppearanceVariant? = nil,
    userDefaults: UserDefaults = .standard
  ) {
    var value = storage(userDefaults: userDefaults)
    let prefix = variant.map { "\(preset.rawValue).\($0.rawValue)." } ?? "\(preset.rawValue)."
    value.colors = value.colors.filter { !$0.key.hasPrefix(prefix) }
    save(value, userDefaults: userDefaults)
  }

  public static func export(
    preset: AppThemePreset,
    userDefaults: UserDefaults = .standard
  ) -> String {
    guard let data = try? exportData(preset: preset, userDefaults: userDefaults) else { return "" }
    return String(bytes: data, encoding: .utf8) ?? ""
  }

  public static func exportData(
    preset: AppThemePreset,
    userDefaults: UserDefaults = .standard
  ) throws -> Data {
    let export = ThemePaletteFile(
      preset: preset.rawValue,
      light: exportPalette(preset: preset, variant: .light, userDefaults: userDefaults),
      dark: exportPalette(preset: preset, variant: .dark, userDefaults: userDefaults)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(export)
  }

  @discardableResult
  public static func importData(
    _ data: Data,
    userDefaults: UserDefaults = .standard
  ) throws -> AppThemePreset {
    let file = try JSONDecoder().decode(ThemePaletteFile.self, from: data)
    guard let preset = AppThemePreset(rawValue: file.preset) else {
      throw ThemePaletteFileError.unknownPreset(file.preset)
    }

    let palettes: [ThemeAppearanceVariant: ThemePalette] = [
      .light: try file.light.themePalette(),
      .dark: try file.dark.themePalette(),
    ]

    var value = storage(userDefaults: userDefaults)
    let prefix = "\(preset.rawValue)."
    value.colors = value.colors.filter { !$0.key.hasPrefix(prefix) }

    for (variant, palette) in palettes {
      for role in editableRoles(for: preset) {
        value.colors[key(preset: preset, variant: variant, role: role)] = palette[role]
      }
    }

    save(value, userDefaults: userDefaults)
    return preset
  }

  private static func exportPalette(
    preset: AppThemePreset,
    variant: ThemeAppearanceVariant,
    userDefaults: UserDefaults
  ) -> ThemePaletteFile.Palette {
    let palette = Theme.resolvedPalette(
      preset: preset,
      variant: variant,
      userDefaults: userDefaults
    )
    return .init(
      accent: palette.accent.hexRGB,
      prominent: palette.prominent.hexRGB,
      bubble: palette.bubble.hexRGB,
      background: palette.background.hexRGB
    )
  }

  private static func key(
    preset: AppThemePreset,
    variant: ThemeAppearanceVariant,
    role: ThemeColorRole
  ) -> String {
    "\(preset.rawValue).\(variant.rawValue).\(role.rawValue)"
  }

  private static func editableRoles(for preset: AppThemePreset) -> [ThemeColorRole] {
    preset == .system ? [.bubble] : ThemeColorRole.allCases
  }

  private static func storage(userDefaults: UserDefaults) -> Storage {
    guard let data = userDefaults.data(forKey: storageKey),
          let value = try? JSONDecoder().decode(Storage.self, from: data)
    else { return Storage() }
    return value
  }

  private static func save(_ value: Storage, userDefaults: UserDefaults) {
    guard value.colors.isEmpty == false else {
      userDefaults.removeObject(forKey: storageKey)
      return
    }
    guard let data = try? JSONEncoder().encode(value) else { return }
    userDefaults.set(data, forKey: storageKey)
  }

  private struct Storage: Codable {
    var colors: [String: ThemeColorValue] = [:]
  }

  private struct ThemePaletteFile: Codable {
    struct Palette: Codable {
      let accent: String
      let prominent: String
      let bubble: String
      let background: String

      func themePalette() throws -> ThemePalette {
        try ThemePalette(
          accent: color(accent, role: .accent),
          prominent: color(prominent, role: .prominent),
          bubble: color(bubble, role: .bubble),
          background: color(background, role: .background)
        )
      }

      private func color(_ value: String, role: ThemeColorRole) throws -> ThemeColorValue {
        guard let color = ThemeColorValue(hexRGB: value) else {
          throw ThemePaletteFileError.invalidColor(role: role, value: value)
        }
        return color
      }
    }

    let preset: String
    let light: Palette
    let dark: Palette
  }

  private enum ThemePaletteFileError: LocalizedError {
    case unknownPreset(String)
    case invalidColor(role: ThemeColorRole, value: String)

    var errorDescription: String? {
      switch self {
      case let .unknownPreset(preset):
        "Unknown theme preset: \(preset)"
      case let .invalidColor(role, value):
        "Invalid \(role.rawValue) color: \(value)"
      }
    }
  }
}

extension NSColor {
  func resolvedThemeColor(with appearance: NSAppearance) -> NSColor {
    var resolved = self
    appearance.performAsCurrentDrawingAppearance {
      resolved = usingColorSpace(.sRGB) ?? usingColorSpace(.deviceRGB) ?? self
    }
    return resolved
  }
}

private extension Double {
  func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
