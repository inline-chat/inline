import InlineTheme
import SwiftUI
import UIKit

protocol ThemeConfig {
  var backgroundColor: UIColor { get }
  var accent: UIColor { get }

  var bubbleBackground: UIColor { get }
  var incomingBubbleBackground: UIColor { get }
  var failedBubbleBackground: UIColor { get }

  // only for incoming messages for now
  var primaryTextColor: UIColor? { get }
  var secondaryTextColor: UIColor? { get }

  var reactionOutgoingPrimary: UIColor? { get }
  var reactionOutgoingSecoundry: UIColor? { get }

  var reactionIncomingPrimary: UIColor? { get }
  var reactionIncomingSecoundry: UIColor? { get }

  var documentIconBackground: UIColor? { get }

  // New Catppuccin Mocha colors for comprehensive theming
  var listRowBackground: UIColor? { get }
  var listSeparatorColor: UIColor? { get }
  var navigationBarBackground: UIColor? { get }
  var toolbarBackground: UIColor? { get }
  var surfaceBackground: UIColor? { get }
  var surfaceSecondary: UIColor? { get }
  var textPrimary: UIColor? { get }
  var textSecondary: UIColor? { get }
  var textTertiary: UIColor? { get }
  var borderColor: UIColor? { get }
  var overlayBackground: UIColor? { get }
  var cardBackground: UIColor? { get }
  var searchBarBackground: UIColor? { get }
  var buttonBackground: UIColor? { get }
  var buttonSecondaryBackground: UIColor? { get }
  var sheetTintColor: UIColor? { get }
  var logoutRed: UIColor { get }

  var id: String { get }
  var name: String { get }
}

struct IOSThemeSnapshot: Equatable {
  let preset: AppThemePreset
  let variant: ThemeAppearanceVariant
  let primary: ThemeColorValue
  let chatCanvas: ThemeColorValue
  let outgoingBubble: ThemeColorValue
  let incomingBubble: ThemeColorValue
  let incomingText: ThemeColorValue
  let incomingSecondaryText: ThemeColorValue
  let outgoingLighting: ThemeBubbleLightingAlphas
  let incomingLighting: ThemeBubbleLightingAlphas

  static func resolve(
    preset: AppThemePreset,
    variant: ThemeAppearanceVariant
  ) -> Self {
    let nativeCanvas = ThemeColorValue(rgb: variant == .dark ? 0x000000 : 0xFFFFFF)
    let palette = ThemeCatalog.palette(
      preset: preset,
      variant: variant,
      systemCanvas: nativeCanvas
    )
    let chatCanvas = preset == .system
      ? nativeCanvas
      : nativeCanvas.blended(with: palette.canvas, amount: variant == .dark ? 0.189 : 0.126)

    return Self(
      preset: preset,
      variant: variant,
      primary: palette.primary,
      chatCanvas: chatCanvas,
      outgoingBubble: palette.bubble,
      incomingBubble: ThemeCatalog.secondaryBubble(preset: preset, variant: variant),
      incomingText: .init(rgb: variant == .dark ? 0xFFFFFF : 0x000000),
      incomingSecondaryText: .init(
        rgb: variant == .dark ? 0xFFFFFF : 0x000000,
        alpha: variant == .dark ? 0.7 : 0.58
      ),
      outgoingLighting: ThemeCatalog.messageBubbleGradientOverlayAlphas(
        variant: variant,
        outgoing: true
      ),
      incomingLighting: ThemeCatalog.messageBubbleGradientOverlayAlphas(
        variant: variant,
        outgoing: false
      )
    )
  }
}

final class ThemeManager: ObservableObject {
  static let shared = ThemeManager()

  static let themes: [SharedThemeConfig] = AppThemePreset.allCases.map(SharedThemeConfig.init)

  private let defaults = UserDefaults.standard
  private let selectedPresetKey = "iosAppThemePreset"
  private let legacyThemeKey = "selected_theme_id"

  @Published private(set) var selectedPreset: AppThemePreset {
    didSet {
      defaults.set(selectedPreset.rawValue, forKey: selectedPresetKey)
    }
  }

  init() {
    if let savedPreset = defaults.string(forKey: selectedPresetKey),
       let preset = AppThemePreset(rawValue: savedPreset) {
      selectedPreset = preset
    } else {
      let legacyIdentifier = defaults.string(forKey: legacyThemeKey)
      selectedPreset = AppThemePreset(migratingLegacyIOSIdentifier: legacyIdentifier)
      if legacyIdentifier != nil {
        defaults.set(selectedPreset.rawValue, forKey: selectedPresetKey)
      }
    }
  }

  var selected: ThemeConfig {
    SharedThemeConfig(preset: selectedPreset)
  }

  func snapshot(variant: ThemeAppearanceVariant) -> IOSThemeSnapshot {
    .resolve(preset: selectedPreset, variant: variant)
  }

  func switchToTheme(_ theme: ThemeConfig) {
    switchToTheme(withID: theme.id)
  }

  func switchToTheme(withID id: String) {
    guard let preset = AppThemePreset(rawValue: id), preset != selectedPreset else { return }
    selectedPreset = preset
  }

  func resetToDefaultTheme() {
    selectedPreset = .system
  }

  // MARK: - Helper Methods

  static func findTheme(withID id: String) -> ThemeConfig? {
    themes.first { $0.id == id }
  }
}

struct SharedThemeConfig: ThemeConfig {
  let preset: AppThemePreset

  private func dynamicColor(_ keyPath: KeyPath<IOSThemeSnapshot, ThemeColorValue>) -> UIColor {
    UIColor { traits in
      IOSThemeSnapshot.resolve(
        preset: preset,
        variant: traits.userInterfaceStyle == .dark ? .dark : .light
      )[keyPath: keyPath].uiColor
    }
  }

  var backgroundColor: UIColor { dynamicColor(\.chatCanvas) }
  var accent: UIColor { dynamicColor(\.primary) }
  var bubbleBackground: UIColor { dynamicColor(\.outgoingBubble) }
  var incomingBubbleBackground: UIColor { dynamicColor(\.incomingBubble) }
  var failedBubbleBackground: UIColor { .systemRed }
  var primaryTextColor: UIColor? { dynamicColor(\.incomingText) }
  var secondaryTextColor: UIColor? { dynamicColor(\.incomingSecondaryText) }
  var reactionOutgoingPrimary: UIColor? { UIColor.white.withAlphaComponent(0.2) }
  var reactionOutgoingSecoundry: UIColor? { UIColor.white.withAlphaComponent(0.12) }
  var reactionIncomingPrimary: UIColor? { accent.withAlphaComponent(0.18) }
  var reactionIncomingSecoundry: UIColor? { incomingBubbleBackground }
  var documentIconBackground: UIColor? { accent.withAlphaComponent(0.16) }
  var listRowBackground: UIColor? { nil }
  var listSeparatorColor: UIColor? { nil }
  var navigationBarBackground: UIColor? { nil }
  var toolbarBackground: UIColor? { nil }
  var surfaceBackground: UIColor? { nil }
  var surfaceSecondary: UIColor? { nil }
  var textPrimary: UIColor? { nil }
  var textSecondary: UIColor? { nil }
  var textTertiary: UIColor? { nil }
  var borderColor: UIColor? { nil }
  var overlayBackground: UIColor? { nil }
  var cardBackground: UIColor? { nil }
  var searchBarBackground: UIColor? { nil }
  var buttonBackground: UIColor? { accent }
  var buttonSecondaryBackground: UIColor? { nil }
  var sheetTintColor: UIColor? { accent }
  var logoutRed: UIColor { .systemRed }
  var id: String { preset.rawValue }
  var name: String { preset.title }
}

extension ThemeAppearanceVariant {
  init(colorScheme: ColorScheme) {
    self = colorScheme == .dark ? .dark : .light
  }
}

extension ThemeColorValue {
  var uiColor: UIColor {
    UIColor(
      red: CGFloat(red),
      green: CGFloat(green),
      blue: CGFloat(blue),
      alpha: CGFloat(alpha)
    )
  }

  fileprivate func blended(with other: ThemeColorValue, amount: Double) -> ThemeColorValue {
    let fraction = min(max(amount, 0), 1)
    return ThemeColorValue(
      red: red + (other.red - red) * fraction,
      green: green + (other.green - green) * fraction,
      blue: blue + (other.blue - blue) * fraction,
      alpha: alpha + (other.alpha - alpha) * fraction
    )
  }
}

// MARK: - SwiftUI Color Extensions

extension ThemeManager {
  var surfaceBackgroundColor: Color {
    Color(selected.surfaceBackground ?? .secondarySystemBackground)
  }

  var surfaceSecondaryColor: Color {
    Color(selected.surfaceSecondary ?? .tertiarySystemBackground)
  }

  var textPrimaryColor: Color {
    Color(selected.textPrimary ?? .label)
  }

  var textSecondaryColor: Color {
    Color(selected.textSecondary ?? .secondaryLabel)
  }

  var textTertiaryColor: Color {
    Color(selected.textTertiary ?? .tertiaryLabel)
  }

  var borderColor: Color {
    Color(selected.borderColor ?? .separator)
  }

  var overlayBackgroundColor: Color {
    Color(selected.overlayBackground ?? .systemGray)
  }

  var cardBackgroundColor: Color {
    Color(selected.cardBackground ?? .secondarySystemBackground)
  }

  var searchBarBackgroundColor: Color {
    Color(selected.searchBarBackground ?? .systemGray6)
  }

  var buttonBackgroundColor: Color {
    Color(selected.buttonBackground ?? selected.accent)
  }

  var buttonSecondaryBackgroundColor: Color {
    Color(selected.buttonSecondaryBackground ?? .systemGray2)
  }

  var accentColor: Color {
    Color(selected.accent)
  }

  var sheetTintColor: Color {
    Color(selected.sheetTintColor ?? selected.accent)
  }

  var logoutRedColor: Color {
    Color(selected.logoutRed)
  }
}
