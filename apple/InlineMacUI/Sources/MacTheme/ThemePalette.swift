import AppKit
import Foundation
import InlineTheme

public typealias AppThemePreset = InlineTheme.AppThemePreset
public typealias ThemeAppearanceVariant = InlineTheme.ThemeAppearanceVariant
public typealias ThemeColorRole = InlineTheme.ThemeColorRole
public typealias ThemeSeedRole = InlineTheme.ThemeSeedRole
public typealias ThemeColorValue = InlineTheme.ThemeColorValue
public typealias ThemePalette = InlineTheme.ThemePalette

public extension ThemeAppearanceVariant {
  init(appearance: NSAppearance) {
    self = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
  }

  var nsAppearance: NSAppearance {
    guard let appearance = NSAppearance(named: self == .dark ? .darkAqua : .aqua) else {
      preconditionFailure("Built-in Aqua appearance is unavailable")
    }
    return appearance
  }
}

public extension ThemeColorValue {
  init(nsColor: NSColor, appearance: NSAppearance) {
    let color = nsColor.resolvedThemeColor(with: appearance)
    self.init(
      red: Double(color.redComponent),
      green: Double(color.greenComponent),
      blue: Double(color.blueComponent),
      alpha: Double(color.alphaComponent)
    )
  }

  var nsColor: NSColor {
    NSColor(
      srgbRed: CGFloat(red),
      green: CGFloat(green),
      blue: CGFloat(blue),
      alpha: CGFloat(alpha)
    )
  }
}

public enum ThemePreference {
  public static let selectedPresetKey = "macAppThemePreset"
  /// Obsolete but intentionally retained so older builds can still read their preference.
  public static let selectedSystemAccentKey = "macAppThemeSystemAccent"
  public static let sidebarGlassAndTintEnabledKey = "macSidebarGlassAndTintEnabled"

  public static func selectedPreset(userDefaults: UserDefaults = .standard) -> AppThemePreset {
    guard let rawValue = userDefaults.string(forKey: selectedPresetKey),
          let preset = AppThemePreset(rawValue: rawValue)
    else { return .system }
    return preset
  }

  public static func sidebarGlassAndTintEnabled(
    userDefaults: UserDefaults = .standard
  ) -> Bool {
    userDefaults.object(forKey: sidebarGlassAndTintEnabledKey) as? Bool ?? true
  }
}

public enum ThemePaletteOverrides {
  public static let storageKey = "macAppThemeOverrides.v2"
  public static let legacyStorageKey = "macAppThemeDebugOverrides.v1"
  public static let legacyMigrationKey = "macAppThemeOverridesMigratedToV2"

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
    for role in editableSeedRoles(for: preset) {
      if let color = colors[key(preset: preset, variant: variant, role: role)] {
        palette[seed: role] = color
      }
    }
    return palette
  }

  public static func setColor(
    _ color: ThemeColorValue,
    preset: AppThemePreset,
    variant: ThemeAppearanceVariant,
    role: ThemeSeedRole,
    userDefaults: UserDefaults = .standard
  ) {
    guard editableSeedRoles(for: preset).contains(role) else { return }
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
      version: 2,
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
    guard file.version == nil || file.version == 1 || file.version == 2 else {
      throw ThemePaletteFileError.unsupportedVersion(file.version ?? 0)
    }
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
      for role in editableSeedRoles(for: preset) {
        value.colors[key(preset: preset, variant: variant, role: role)] = palette[seed: role]
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
      primary: palette.primary.hexRGB,
      canvas: palette.canvas.hexRGB
    )
  }

  private static func key(
    preset: AppThemePreset,
    variant: ThemeAppearanceVariant,
    role: ThemeSeedRole
  ) -> String {
    "\(preset.rawValue).\(variant.rawValue).\(role.rawValue)"
  }

  private static func editableSeedRoles(for preset: AppThemePreset) -> [ThemeSeedRole] {
    preset == .system ? [.primary] : ThemeSeedRole.allCases
  }

  private static func storage(userDefaults: UserDefaults) -> Storage {
    if let data = userDefaults.data(forKey: storageKey),
       let value = try? JSONDecoder().decode(Storage.self, from: data) {
      return value
    }

    guard userDefaults.bool(forKey: legacyMigrationKey) == false,
          let data = userDefaults.data(forKey: legacyStorageKey),
          let legacy = try? JSONDecoder().decode(Storage.self, from: data)
    else { return Storage() }

    let migrated = migrateLegacyStorage(legacy)
    save(migrated, userDefaults: userDefaults)
    userDefaults.set(true, forKey: legacyMigrationKey)
    return migrated
  }

  private static func migrateLegacyStorage(_ legacy: Storage) -> Storage {
    var migrated = Storage()
    for preset in AppThemePreset.allCases {
      for variant in ThemeAppearanceVariant.allCases {
        for role in editableSeedRoles(for: preset) {
          let color: ThemeColorValue? = switch role {
          case .primary:
            legacy.colors[legacyKey(preset: preset, variant: variant, role: .bubble)]
              ?? legacy.colors[legacyKey(preset: preset, variant: variant, role: .prominent)]
              ?? legacy.colors[legacyKey(preset: preset, variant: variant, role: .accent)]
          case .canvas:
            legacy.colors[legacyKey(preset: preset, variant: variant, role: .background)]
          }
          if let color {
            migrated.colors[key(preset: preset, variant: variant, role: role)] = color
          }
        }
      }
    }
    return migrated
  }

  private static func legacyKey(
    preset: AppThemePreset,
    variant: ThemeAppearanceVariant,
    role: ThemeColorRole
  ) -> String {
    "\(preset.rawValue).\(variant.rawValue).\(role.rawValue)"
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
      let primary: String?
      let canvas: String?
      let accent: String?
      let prominent: String?
      let bubble: String?
      let background: String?

      init(primary: String, canvas: String) {
        self.primary = primary
        self.canvas = canvas
        accent = nil
        prominent = nil
        bubble = nil
        background = nil
      }

      func themePalette() throws -> ThemePalette {
        let primaryValue = primary ?? bubble ?? prominent ?? accent
        let canvasValue = canvas ?? background
        guard let primaryValue else { throw ThemePaletteFileError.missingColor("primary") }
        guard let canvasValue else { throw ThemePaletteFileError.missingColor("canvas") }
        return try ThemePalette(
          primary: color(primaryValue, field: "primary"),
          canvas: color(canvasValue, field: "canvas")
        )
      }

      private func color(_ value: String, field: String) throws -> ThemeColorValue {
        guard let color = ThemeColorValue(hexRGB: value) else {
          throw ThemePaletteFileError.invalidColor(field: field, value: value)
        }
        return color
      }
    }

    let version: Int?
    let preset: String
    let light: Palette
    let dark: Palette
  }

  private enum ThemePaletteFileError: LocalizedError {
    case unsupportedVersion(Int)
    case unknownPreset(String)
    case missingColor(String)
    case invalidColor(field: String, value: String)

    var errorDescription: String? {
      switch self {
      case let .unsupportedVersion(version):
        "Unsupported theme file version: \(version)"
      case let .unknownPreset(preset):
        "Unknown theme preset: \(preset)"
      case let .missingColor(field):
        "Missing \(field) color"
      case let .invalidColor(field, value):
        "Invalid \(field) color: \(value)"
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
