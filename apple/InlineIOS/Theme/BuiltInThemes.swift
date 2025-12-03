import UIKit

extension AppTheme {
  static let allThemes: [AppTheme] = [.default, .catppuccinMocha, .peonyPink, .orchid]

  // MARK: - Default Theme

  static let `default` = AppTheme(
    id: "Default",
    name: "Default",
    colors: .systemDefaults
  )

  // MARK: - Catppuccin Mocha

  static let catppuccinMocha = AppTheme(
    id: "CatppuccinMocha",
    name: "Catppuccin Mocha",
    colors: ThemeColors(
      bubbleOutgoing: .dynamic(light: "#7287FD", dark: "#919EF4"),
      bubbleIncoming: .dynamic(light: "#EFF1F5", dark: "#313244"),
      bubbleFailed: UIColor(hex: "#f38ba8")!,
      accent: .dynamic(light: "#7287FD", dark: "#919EF4"),
      textPrimary: .dynamic(light: "#4C4F69", dark: "#FFFFFF"),
      textSecondary: .dynamic(light: "#4C4F69", dark: "#CDD6F4"),
      textTertiary: .dynamic(light: "#6C6F85", dark: "#A6ADC8"),
      background: .dynamic(light: "#FFFFFF", dark: "#11111B"),
      surface: .dynamic(light: "#CCD0DA", dark: "#313244"),
      surfaceSecondary: .dynamic(light: "#BCC0CC", dark: "#45475A"),
      card: .dynamic(light: "#E6E9EF", dark: "#181825"),
      reactionOutgoingPrimary: .white,
      reactionOutgoingSecondary: .white.withAlphaComponent(0.08),
      reactionIncomingPrimary: .dynamic(light: "#7287FD", dark: "#919EF4"),
      reactionIncomingSecondary: .dynamic(light: "#dddfe6", dark: "#41435d"),
      documentIconBackground: .dynamic(light: "#dddfe6", dark: "#41435d"),
      separator: .dynamic(light: "#9CA0B0", dark: "#6C7086"),
      border: .dynamic(light: "#ACB0BE", dark: "#585B70"),
      overlay: .dynamic(light: "#8C8FA1", dark: "#7F849C"),
      buttonPrimary: .dynamic(light: "#8839EF", dark: "#CBA6F7"),
      buttonSecondary: .dynamic(light: "#BCC0CC", dark: "#45475A"),
      navigationBar: .dynamic(light: "#FFFFFF", dark: "#11111B"),
      toolbar: .dynamic(light: "#FFFFFF", dark: "#11111B"),
      searchBar: .dynamic(light: "#CCD0DA", dark: "#313244"),
      destructive: UIColor(hex: "#f38ba8")!
    )
  )

  // MARK: - Peony Pink

  static let peonyPink = AppTheme(
    id: "PeonyPink",
    name: "Peony Pink",
    colors: ThemeColors(
      bubbleOutgoing: UIColor(hex: "#FF82B8")!,
      bubbleIncoming: .dynamic(light: "#F2F2F2", dark: "#27262B"),
      bubbleFailed: .systemRed,
      accent: UIColor(hex: "#FF82B8")!,
      textPrimary: .label,
      textSecondary: .secondaryLabel,
      textTertiary: .tertiaryLabel,
      background: .systemBackground,
      surface: .secondarySystemBackground,
      surfaceSecondary: .tertiarySystemBackground,
      card: .secondarySystemBackground,
      reactionOutgoingPrimary: .white,
      reactionOutgoingSecondary: .white.withAlphaComponent(0.08),
      reactionIncomingPrimary: UIColor(hex: "#FF82B8")!,
      reactionIncomingSecondary: .dynamic(light: "#e2e5e5", dark: "#3c3b43"),
      documentIconBackground: .dynamic(light: "#e2e5e5", dark: "#3c3b43"),
      separator: .separator,
      border: .separator,
      overlay: .systemGray,
      buttonPrimary: UIColor(hex: "#FF82B8")!,
      buttonSecondary: .systemGray2,
      navigationBar: .systemBackground,
      toolbar: .systemBackground,
      searchBar: .systemGray6,
      destructive: .systemRed
    )
  )

  // MARK: - Orchid

  static let orchid = AppTheme(
    id: "Orchid",
    name: "Orchid",
    colors: ThemeColors(
      bubbleOutgoing: .dynamic(light: "#a28cf2", dark: "#8b77dc"),
      bubbleIncoming: .dynamic(light: "#F2F2F2", dark: "#27262B"),
      bubbleFailed: .systemRed,
      accent: UIColor(hex: "#a28cf2")!,
      textPrimary: .label,
      textSecondary: .secondaryLabel,
      textTertiary: .tertiaryLabel,
      background: .systemBackground,
      surface: .secondarySystemBackground,
      surfaceSecondary: .tertiarySystemBackground,
      card: .secondarySystemBackground,
      reactionOutgoingPrimary: .white,
      reactionOutgoingSecondary: .white.withAlphaComponent(0.08),
      reactionIncomingPrimary: UIColor(hex: "#a28cf2")!,
      reactionIncomingSecondary: .dynamic(light: "#e2e5e5", dark: "#3c3b43"),
      documentIconBackground: .dynamic(light: "#e2e5e5", dark: "#3c3b43"),
      separator: .separator,
      border: .separator,
      overlay: .systemGray,
      buttonPrimary: UIColor(hex: "#a28cf2")!,
      buttonSecondary: .systemGray2,
      navigationBar: .systemBackground,
      toolbar: .systemBackground,
      searchBar: .systemGray6,
      destructive: .systemRed
    )
  )
}
