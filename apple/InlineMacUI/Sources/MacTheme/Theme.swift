import AppKit
import Cocoa
import Foundation
import SwiftUI

// System colors: https://gist.github.com/andrejilderda/8677c565cddc969e6aae7df48622d47c

public enum Theme {
  // MARK: - General

  public static let pageBackgroundMaterial: NSVisualEffectView.Material = .contentBackground
  public static let whiteOnLight: NSColor = .init(name: "whiteOrBlack") { appearance in
    appearance.name == .darkAqua ? NSColor.black : NSColor.white
  }

  // MARK: - Colors

  public static let colorIconGray: NSColor = .init(name: "colorIconGray") { appearance in
    appearance.name == .darkAqua ?
      NSColor(red: 146 / 255, green: 146 / 255, blue: 146 / 255, alpha: 1) :
      NSColor(red: 188 / 255, green: 188 / 255, blue: 188 / 255, alpha: 1)
  }

  public static let colorTitleTextGray: NSColor = .init(name: "colorTitleTextGray") { appearance in
    appearance.name == .darkAqua ?
      NSColor(red: 160 / 255, green: 160 / 255, blue: 160 / 255, alpha: 1) :
      NSColor(red: 158 / 255, green: 158 / 255, blue: 158 / 255, alpha: 1)
  }

  /// Theme colors are computed so changing presets creates a fresh dynamic color.
  /// These colors must remain unnamed: SwiftUI compares named NSColors by name,
  /// which would make two different theme values appear equal during live updates.
  public static var accentColor: NSColor {
    semanticColor(role: .accent)
  }

  public static var prominentColor: NSColor {
    semanticColor(role: .prominent)
  }

  public static func resolvedColor(
    role: ThemeColorRole,
    preset: AppThemePreset,
    variant: ThemeAppearanceVariant,
    userDefaults: UserDefaults = .standard
  ) -> ThemeColorValue {
    resolvedPalette(
      preset: preset,
      variant: variant,
      userDefaults: userDefaults
    )[role]
  }

  public static func resolvedPalette(
    preset: AppThemePreset,
    variant: ThemeAppearanceVariant,
    userDefaults: UserDefaults = .standard
  ) -> ThemePalette {
    ThemePaletteOverrides.applyingOverrides(
      to: basePalette(preset: preset, variant: variant),
      preset: preset,
      variant: variant,
      userDefaults: userDefaults
    )
  }

  // MARK: - Window

  public static let windowMinimumSize: CGSize = .init(width: 320, height: 300)
  public static var windowBackgroundColor: NSColor {
    windowContentBackgroundColor
  }

  public static var windowContentBackgroundColor: NSColor {
    .init(name: nil) { appearance in
      let preset = ThemePreference.selectedPreset()
      let variant = ThemeAppearanceVariant(appearance: appearance)
      return resolvedWindowSurfaceColor(preset: preset, variant: variant).nsColor
    }
  }

  public static var settingsWindowBackgroundColor: NSColor {
    windowContentBackgroundColor
  }

  public static func resolvedWindowSurfaceColor(
    preset: AppThemePreset,
    variant: ThemeAppearanceVariant,
    userDefaults: UserDefaults = .standard
  ) -> ThemeColorValue {
    let appearance = variant.nsAppearance
    let native = NSColor.windowBackgroundColor.resolvedColor(with: appearance)
    guard preset != .system else {
      return ThemeColorValue(nsColor: native, appearance: appearance)
    }

    let canvas = resolvedPalette(
      preset: preset,
      variant: variant,
      userDefaults: userDefaults
    ).canvas.nsColor
    let amount: CGFloat = variant == .dark ? 0.189 : 0.126
    let surface = native.blended(withFraction: amount, of: canvas) ?? native
    return ThemeColorValue(nsColor: surface, appearance: appearance)
  }

  public static var sidebarOverlayColor: NSColor {
    .init(name: nil) { appearance in
      let preset = ThemePreference.selectedPreset()
      let variant = ThemeAppearanceVariant(appearance: appearance)
      return resolvedSidebarOverlayColor(preset: preset, variant: variant).nsColor
    }
  }

  public static func resolvedSidebarOverlayColor(
    preset: AppThemePreset,
    variant: ThemeAppearanceVariant,
    userDefaults: UserDefaults = .standard
  ) -> ThemeColorValue {
    guard ThemePreference.sidebarGlassAndTintEnabled(userDefaults: userDefaults),
          preset != .system
    else {
      return ThemeColorValue(red: 0, green: 0, blue: 0, alpha: 0)
    }

    let accent = resolvedColor(
      role: .accent,
      preset: preset,
      variant: variant,
      userDefaults: userDefaults
    ).nsColor.withAlphaComponent(variant == .dark ? 0.042 : 0.02625)
    return ThemeColorValue(nsColor: accent, appearance: variant.nsAppearance)
  }

  /// A subtle inspector-like tint that still belongs to the main chat surface family.
  public static var replyThreadPaneBackgroundColor: NSColor {
    .init(name: nil) { appearance in
      let background = windowContentBackgroundColor.resolvedColor(with: appearance)
      guard ThemePreference.selectedPreset() != .system else { return background }
      let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      let tint = isDark ? NSColor.white : NSColor.black
      return background.blended(withFraction: 0.025, of: tint) ?? background
    }
  }

  // MARK: - Main View & Split View

  public static let collapseSidebarAtWindowSize: CGFloat = 500
  public static let toolbarHeight: CGFloat = 46

  // MARK: - Tab Bar

  public static let tabBarHeight: CGFloat = 42
  public static let tabBarItemHeight: CGFloat = 36
  public static let tabBarItemInset: CGFloat = 4

  // MARK: - Main Split View

  // public static let mainSplitViewInnerPadding: CGFloat = 10
  // public static let mainSplitViewContentRadius: CGFloat = 16
  // public static let mainSplitViewInnerPadding: CGFloat = 8
  // public static let mainSplitViewContentRadius: CGFloat = 18
  public static let mainSplitViewUseFullBleedContent: Bool = false
  public static let mainSplitViewInnerPadding: CGFloat = 7
  public static let mainSplitViewContentRadius: CGFloat = 11

  // MARK: - Sidebar

  /// 190 is minimum that fits both sidebar collapse button and plus button
  public static let minimumSidebarWidth: CGFloat = 180
  public static let idealSidebarWidth: CGFloat = 240
  public static let maximumSidebarWidth: CGFloat = 340
  public static let sidebarItemRadius: CGFloat = 10
  public static let sidebarItemPadding: CGFloat = 7.0
  // extra to above padding. note: weird thing is making this 3.0 fucks up home sidebar.
  public static let sidebarItemLeadingGutter: CGFloat = 4.0
  public static let sidebarItemSpacing: CGFloat = 1
  public static let sidebarTopItemFont: Font = .body.weight(.regular)
  public static let sidebarTopItemHeight: CGFloat = 24

  public static let sidebarIconSpacing: CGFloat = 9
  public static let sidebarTitleIconSize: CGFloat = 24
  public static let sidebarIconSize: CGFloat = 24
  public static let sidebarItemHeight: CGFloat = 34
  public static let sidebarTitleItemFont: Font = .system(size: 13.0, weight: .medium)
  public static let sidebarItemFont: Font = .system(size: 13.0, weight: .regular)
  public static let sidebarContentSideSpacing: CGFloat = 17.0 // from inner content of item to edge of sidebar
  public static let sidebarItemInnerSpacing: CGFloat =
    11.0 // from inner content of item to edge of content active/hover style
  public static let sidebarItemOuterSpacing: CGFloat = Theme.sidebarContentSideSpacing - Theme.sidebarItemInnerSpacing
  public static let sidebarItemUnreadDotSize: CGFloat = 5.0
  /// Centers the dot between the row's leading edge and the avatar.
  public static let sidebarItemUnreadDotLeadingSpacing: CGFloat =
    (Theme.sidebarItemInnerSpacing - Theme.sidebarItemUnreadDotSize) / 2
  public static let sidebarNativeDefaultEdgeInsets: CGFloat = 16.0

  // MARK: - Message View

  public static let messageMaxWidth: CGFloat = 420
  public static let messageOuterVerticalPadding: CGFloat = 1.0 // gap between consequetive messages
  public static let messageSidePadding: CGFloat = 16.0
  public static let messageAvatarSize: CGFloat = 28
  // between avatar and content
  public static let messageHorizontalStackSpacing: CGFloat = 8.0
  public static let messageNameLabelHeight: CGFloat = 16
  public nonisolated(unsafe) static let messageTextFont: NSFont = .systemFont(
    ofSize: NSFont.systemFontSize
  )
  public static let messageTextFontSize: Double = NSFont.systemFontSize
  public static let messageTextFontSizeSingleEmoji = 64.0
  public static let messageTextFontSizeThreeEmojis = 42.0
  public static let messageTextFontSizeManyEmojis = 18.0
  public static let messageTextLineFragmentPadding: CGFloat = 0
  public static let messageTextContainerInset: NSSize = .zero
  public static let messageTextViewPadding: CGFloat = 0
  public static let messageContentViewSpacing: CGFloat = 8.0
  static var messageRowMaxWidth: CGFloat {
    Theme.messageMaxWidth + Theme.messageAvatarSize + Theme.messageSidePadding + Theme
      .messageHorizontalStackSpacing + Theme.messageRowSafeAreaInset
  }

  // - after bubble -
  public static var messageBubblePrimaryBgColor: NSColor {
    semanticColor(role: .bubble)
  }

  public static let messageBubbleGradientTopOverlayAlpha: CGFloat = 0.26
  public static let messageBubbleGradientBottomOverlayAlpha: CGFloat = 0.02

  public static func messageBubbleGradientOverlayAlphas(
    variant: ThemeAppearanceVariant,
    outgoing: Bool
  ) -> (top: CGFloat, bottom: CGFloat) {
    guard variant == .dark else {
      return (messageBubbleGradientTopOverlayAlpha, messageBubbleGradientBottomOverlayAlpha)
    }

    // Dark bubbles need a quieter lighting range than Light. Incoming neutral
    // surfaces take less white than outgoing colored surfaces so they do not
    // swing from washed out at the top to nearly black at the bottom.
    let strength: CGFloat = outgoing ? 0.6 : 0.4
    return (
      messageBubbleGradientTopOverlayAlpha * strength,
      messageBubbleGradientBottomOverlayAlpha * strength
    )
  }

  public static func messageBubbleGradientOverlayAlphas(
    appearance: NSAppearance,
    outgoing: Bool
  ) -> (top: CGFloat, bottom: CGFloat) {
    messageBubbleGradientOverlayAlphas(
      variant: ThemeAppearanceVariant(appearance: appearance),
      outgoing: outgoing
    )
  }

  public static func messageBubbleGradientOverlayAlpha(
    atWindowFraction fraction: CGFloat
  ) -> CGFloat {
    let progress = min(max(fraction, 0), 1)
    return messageBubbleGradientTopOverlayAlpha
      + (messageBubbleGradientBottomOverlayAlpha - messageBubbleGradientTopOverlayAlpha) * progress
  }

  public static func messageBubbleGradientOverlayAlpha(
    atWindowFraction fraction: CGFloat,
    variant: ThemeAppearanceVariant,
    outgoing: Bool
  ) -> CGFloat {
    let progress = min(max(fraction, 0), 1)
    let alphas = messageBubbleGradientOverlayAlphas(variant: variant, outgoing: outgoing)
    return alphas.top + (alphas.bottom - alphas.top) * progress
  }

  public static var messageBubbleSecondaryBgColor: NSColor {
    .init(name: nil) { appearance in
      let preset = ThemePreference.selectedPreset()
      let variant = ThemeAppearanceVariant(appearance: appearance)
      return resolvedSecondaryBubbleColor(preset: preset, variant: variant).nsColor
    }
  }

  public static func resolvedSecondaryBubbleColor(
    preset: AppThemePreset,
    variant: ThemeAppearanceVariant,
    userDefaults: UserDefaults = .standard
  ) -> ThemeColorValue {
    if preset == .system {
      if variant == .light {
        return .init(rgb: 0xECECEC)
      }
    }

    // Incoming bubbles are a neutral supporting surface, not a third authored
    // theme color. Styled Light themes share a clean gray; every dark theme uses
    // OpenCode V2's neutral grey-900. Combined with the quieter Dark incoming
    // lighting, its midpoint stays close to the earlier lower-window tone.
    if variant == .light {
      return .init(rgb: 0xEAEAEA)
    }
    return .init(rgb: 0x2E2E2E)
  }

  public static var messageBubbleSecondaryTextColor: NSColor {
    .init(name: nil) { appearance in
      let variant = ThemeAppearanceVariant(appearance: appearance)
      return resolvedSecondaryBubbleTextColor(variant: variant).nsColor
    }
  }

  public static func resolvedSecondaryBubbleTextColor(
    variant: ThemeAppearanceVariant
  ) -> ThemeColorValue {
    if variant == .dark {
      return .init(rgb: 0xFFFFFF)
    }
    return ThemeColorValue(nsColor: .labelColor, appearance: variant.nsAppearance)
  }

  public static var messageBubbleSecondaryLinkColor: NSColor {
    .init(name: nil) { appearance in
      let preset = ThemePreference.selectedPreset()
      let variant = ThemeAppearanceVariant(appearance: appearance)
      return resolvedSecondaryBubbleLinkColor(preset: preset, variant: variant).nsColor
    }
  }

  public static func resolvedSecondaryBubbleLinkColor(
    preset: AppThemePreset,
    variant: ThemeAppearanceVariant,
    userDefaults: UserDefaults = .standard
  ) -> ThemeColorValue {
    let primary = resolvedPalette(
      preset: preset,
      variant: variant,
      userDefaults: userDefaults
    ).primary

    let resolved = primary.nsColor.usingColorSpace(.sRGB) ?? primary.nsColor
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 0
    var alpha: CGFloat = 0
    resolved.getHue(
      &hue,
      saturation: &saturation,
      brightness: &brightness,
      alpha: &alpha
    )

    let color: NSColor
    switch variant {
    case .light:
      // Keep authored accents that already have enough weight. Only cap very
      // bright colors, such as System cyan, to add a small amount of contrast.
      color = NSColor(
        colorSpace: .sRGB,
        hue: hue,
        saturation: saturation,
        brightness: min(brightness, 0.88),
        alpha: alpha
      )
    case .dark:
      // Preserve the primary hue and a visible amount of its saturation while
      // raising brightness. This produces accent-colored ink, not white ink
      // with a trace of the theme color.
      color = NSColor(
        colorSpace: .sRGB,
        hue: hue,
        saturation: saturation * 0.48,
        brightness: max(0.9, min(1, brightness + 0.15)),
        alpha: alpha
      )
    }
    return ThemeColorValue(nsColor: color, appearance: variant.nsAppearance)
  }

  /// used for bubbles diff to edge
  public static let messageRowSafeAreaInset: CGFloat = 50.0
  public static let messageBubbleContentHorizontalInset: CGFloat = 11.0
  public static let messageSingleLineTextOnlyHeight: CGFloat = 28.0
  public static let messageBubbleCornerRadius: CGFloat = 14.0
  public static let messageTimeHeight: CGFloat = 13.0
  public static let messageTextOnlyVerticalInsets: CGFloat = 6.0
  public static let messageTextAndPhotoSpacing: CGFloat = 10.0
  public static let messageTextAndTimeSpacing: CGFloat = 0.0

  // MARK: - Chat View

  public static let chatToolbarIconSize: CGFloat = 30
  /// Renderer-safe minimum for a chat column, including reply-thread panes.
  /// Message/media plans reserve fixed avatar and side insets; validate all narrow
  /// message variants before lowering this contract.
  public static let chatViewMinWidth: CGFloat = 315
  public static let messageGroupSpacing: CGFloat = 8
  public static let messageListTopInset: CGFloat = 14
  public static let messageListBottomInset: CGFloat = 10
  public static let embeddedMessageHeight: CGFloat = 40.0
  public static let documentViewHeight: CGFloat = 36.0
  public static let documentViewWidth: CGFloat = 200.0
  public static let voiceMessageViewHeight: CGFloat = 44.0
  public static let voiceMessageMinimalViewHeight: CGFloat = 34.0
  public static let voiceMessageViewWidth: CGFloat = 216.0
  public static let attachmentViewWidth: CGFloat = 260.0
  public static let externalTaskViewHeight: CGFloat = 46.0
  public static let urlPreviewCompactHeight: CGFloat = 40.0
  public static let urlPreviewLargeHeight: CGFloat = 182.0
  public static let urlPreviewHeight: CGFloat = urlPreviewCompactHeight
  public static let loomPreviewHeight: CGFloat = urlPreviewLargeHeight
  public static let urlPreviewGroupSpacing: CGFloat = 5.0
  public static let urlPreviewGroupBottomSpacing: CGFloat = 2.0
  public static let messageAttachmentsSpacing: CGFloat = 4.0
  public static let scrollButtonSize: CGFloat = 34.0

  public static let composeMinHeight: CGFloat = 44
  public static let composeAttachmentsVPadding: CGFloat = 6
  public static let composeAttachmentImageHeight: CGFloat = 80
  public static let composeButtonSize: CGFloat = 28
  public static let composeTextViewHorizontalPadding: CGFloat = 10.0
  public static let composeVerticalPadding: CGFloat = 2.0 // inner, higher makes 2 line compose increase height
  public static let composeOuterSpacing: CGFloat = 18 // horizontal
  public static let composeOutlineColor: NSColor = .init(name: "composeOutlineColor") { appearance in
    appearance.name == .darkAqua ? NSColor.white
      .withAlphaComponent(0.1) : NSColor.black
      .withAlphaComponent(0.09)
  }

  private static func semanticColor(role: ThemeColorRole) -> NSColor {
    NSColor(name: nil) { appearance in
      let preset = ThemePreference.selectedPreset()
      let variant = ThemeAppearanceVariant(appearance: appearance)
      return resolvedColor(role: role, preset: preset, variant: variant).nsColor
    }
  }

  private static func basePalette(
    preset: AppThemePreset,
    variant: ThemeAppearanceVariant
  ) -> ThemePalette {
    switch (preset, variant) {
    // User-supplied iMessage bottom capture for light; Apple system blue for dark.
    case (.system, .light):
      ThemePalette(
        primary: .init(rgb: 0x00A7F8),
        canvas: .init(nsColor: .windowBackgroundColor, appearance: variant.nsAppearance)
      )
    case (.system, .dark):
      ThemePalette(
        primary: .init(rgb: 0x0A84FF),
        canvas: .init(nsColor: .windowBackgroundColor, appearance: variant.nsAppearance)
      )
    // OpenCode Lucent Orng: https://github.com/anomalyco/opencode
    case (.sunset, .light):
      ThemePalette(
        primary: .init(rgb: 0xC94D24),
        canvas: .init(rgb: 0xFFF5F0)
      )
    case (.sunset, .dark):
      ThemePalette(
        primary: .init(rgb: 0xC94D24),
        canvas: .init(rgb: 0x2A1A15)
      )
    // GitHub Primer default light/dark canvases and action blue.
    case (.midnight, .light):
      ThemePalette(
        primary: .init(rgb: 0x0969DA),
        canvas: .init(rgb: 0xFFFFFF)
      )
    case (.midnight, .dark):
      ThemePalette(
        primary: .init(rgb: 0x0969DA),
        canvas: .init(rgb: 0x0D1117)
      )
    // Linear Ash surface/text pair; its dark canvas comes from Linear Midnight.
    case (.ash, .light):
      ThemePalette(
        primary: .init(rgb: 0x44494D),
        canvas: .init(rgb: 0xFFFFFF)
      )
    case (.ash, .dark):
      ThemePalette(
        primary: .init(rgb: 0x44494D),
        canvas: .init(rgb: 0x151516)
      )
    // Flexoki palette by Steph Ango: https://github.com/kepano/flexoki (MIT).
    case (.flexoki, .light):
      ThemePalette(
        primary: .init(rgb: 0x205EA6),
        canvas: .init(rgb: 0xFFFCF0)
      )
    case (.flexoki, .dark):
      ThemePalette(
        primary: .init(rgb: 0x205EA6),
        canvas: .init(rgb: 0x100F0F)
      )
    // Linear Pale primary with its Barbie Dreamhouse and Pale surfaces.
    case (.pastel, .light):
      ThemePalette(
        primary: .init(rgb: 0x7D57C1),
        canvas: .init(rgb: 0xE2DAF1)
      )
    case (.pastel, .dark):
      ThemePalette(
        primary: .init(rgb: 0x7D57C1),
        canvas: .init(rgb: 0x292D3E)
      )
    // OpenCode V2 purple-700 with OC-2 neutral endpoints.
    case (.neonNoir, .light):
      ThemePalette(
        primary: .init(rgb: 0x623BE2),
        canvas: .init(rgb: 0xF7F7F7)
      )
    case (.neonNoir, .dark):
      ThemePalette(
        primary: .init(rgb: 0x623BE2),
        canvas: .init(rgb: 0x080808)
      )
    }
  }

  // MARK: - Devtools

  public static let devtoolsHeight: CGFloat = 30
}

extension NSColor {
  convenience init(_ name: String, light: NSColor, dark: NSColor) {
    self.init(name: name) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }
  }

  fileprivate func resolvedColor(with appearance: NSAppearance) -> NSColor {
    var resolved: NSColor = self
    appearance.performAsCurrentDrawingAppearance {
      resolved = self.usingType(.componentBased) ?? self.usingColorSpace(.deviceRGB) ?? self
    }
    return resolved
  }
}
