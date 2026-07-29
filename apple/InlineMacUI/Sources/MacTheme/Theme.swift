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
    var palette = ThemePaletteOverrides.applyingOverrides(
      to: basePalette(preset: preset, variant: variant),
      preset: preset,
      variant: variant,
      userDefaults: userDefaults
    )

    if preset == .system {
      let systemAccent = ThemePreference.selectedSystemAccent(userDefaults: userDefaults)
      let nativeAccent = systemAccent.colorValue(appearance: variant.nsAppearance)
      palette.accent = nativeAccent
      palette.prominent = nativeAccent
    }
    return palette
  }

  // MARK: - Window

  public static let windowMinimumSize: CGSize = .init(width: 320, height: 300)
  public static var windowBackgroundColor: NSColor {
    semanticColor(role: .background)
  }

  public static var windowContentBackgroundColor: NSColor {
    semanticColor(role: .background)
  }

  public static var settingsWindowBackgroundColor: NSColor {
    .init(name: nil) { appearance in
      let native = NSColor.windowBackgroundColor.resolvedColor(with: appearance)
      guard ThemePreference.selectedPreset() != .system else { return native }
      let theme = windowContentBackgroundColor.resolvedColor(with: appearance)
      return native.blended(withFraction: 0.7, of: theme) ?? theme
    }
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
    guard preset != .system else {
      return ThemeColorValue(red: 0, green: 0, blue: 0, alpha: 0)
    }

    let accent = resolvedColor(
      role: .accent,
      preset: preset,
      variant: variant,
      userDefaults: userDefaults
    ).nsColor.withAlphaComponent(variant == .dark ? 0.1 : 0.07)
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
    let palette = resolvedPalette(
      preset: preset,
      variant: variant,
      userDefaults: userDefaults
    )

    if preset == .system {
      if variant == .light {
        return .init(rgb: 0xECECEC)
      }

      let color = solidBubbleColor(
        background: palette.background.nsColor,
        overlay: .white,
        alpha: 0.1,
        appearance: variant.nsAppearance
      )
      return ThemeColorValue(nsColor: color, appearance: variant.nsAppearance)
    }

    // A fixed cool-neutral base gives light incoming bubbles reliable separation
    // without darkening warm page colors into muddy gray or brown. A trace of the
    // outgoing hue coordinates the pair. Dark bubbles lift from their own page.
    let neutral = if variant == .light {
      ThemeColorValue(rgb: 0xEDF0F4).nsColor
    } else {
      solidBubbleColor(
        background: palette.background.nsColor,
        overlay: .white,
        alpha: 0.12,
        appearance: variant.nsAppearance
      )
    }
    let color = solidBubbleColor(
      background: neutral,
      overlay: palette.bubble.nsColor,
      alpha: variant == .dark ? 0.07 : 0.045,
      appearance: variant.nsAppearance
    )
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

  private static func solidBubbleColor(
    background: NSColor,
    overlay: NSColor,
    alpha: CGFloat,
    appearance: NSAppearance
  ) -> NSColor {
    let bg = background.resolvedColor(with: appearance).withAlphaComponent(1)
    let fg = overlay.resolvedColor(with: appearance).withAlphaComponent(1)
    return bg.blended(withFraction: alpha, of: fg)?.withAlphaComponent(1) ?? bg
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
    case (.system, .light):
      ThemePalette(
        accent: .init(rgb: 0x0A84FF),
        prominent: .init(rgb: 0x0A84FF),
        bubble: .init(rgb: 0x3395FF),
        background: .init(nsColor: .windowBackgroundColor, appearance: variant.nsAppearance)
      )
    case (.system, .dark):
      ThemePalette(
        accent: .init(rgb: 0x0A84FF),
        prominent: .init(rgb: 0x0A84FF),
        bubble: .init(rgb: 0x0A84FF),
        background: .init(nsColor: .windowBackgroundColor, appearance: variant.nsAppearance)
      )
    case (.sunset, .light):
      ThemePalette(
        accent: .init(rgb: 0xC84165),
        prominent: .init(rgb: 0xC44F3F),
        bubble: .init(rgb: 0xC84643),
        background: .init(rgb: 0xFFF8F5)
      )
    case (.sunset, .dark):
      ThemePalette(
        accent: .init(rgb: 0xC84A69),
        prominent: .init(rgb: 0xC35434),
        bubble: .init(rgb: 0xB8422D),
        background: .init(rgb: 0x21191B)
      )
    case (.midnight, .light):
      ThemePalette(
        accent: .init(rgb: 0x2F6FA8),
        prominent: .init(rgb: 0x385EC7),
        bubble: .init(rgb: 0x3A7BAA),
        background: .init(rgb: 0xF5F8FF)
      )
    case (.midnight, .dark):
      ThemePalette(
        accent: .init(rgb: 0x4C86C6),
        prominent: .init(rgb: 0x4777BC),
        bubble: .init(rgb: 0x3D6A97),
        background: .init(rgb: 0x111827)
      )
    case (.ash, .light):
      ThemePalette(
        accent: .init(rgb: 0x5F6875),
        prominent: .init(rgb: 0x667080),
        bubble: .init(rgb: 0x626B78),
        background: .init(rgb: 0xF6F6F7)
      )
    case (.ash, .dark):
      ThemePalette(
        accent: .init(rgb: 0x6F7886),
        prominent: .init(rgb: 0x6A7483),
        bubble: .init(rgb: 0x3D414D),
        background: .init(rgb: 0x0E0F11)
      )
    // Flexoki palette by Steph Ango: https://github.com/kepano/flexoki (MIT).
    case (.flexoki, .light):
      ThemePalette(
        accent: .init(rgb: 0x66800B),
        prominent: .init(rgb: 0xBC5215),
        bubble: .init(rgb: 0x205EA6),
        background: .init(rgb: 0xFFFCF0)
      )
    case (.flexoki, .dark):
      ThemePalette(
        accent: .init(rgb: 0x879A39),
        prominent: .init(rgb: 0xBC5215),
        bubble: .init(rgb: 0x205EA6),
        background: .init(rgb: 0x100F0F)
      )
    case (.pastel, .light):
      ThemePalette(
        accent: .init(rgb: 0x835FC7),
        prominent: .init(rgb: 0xA95682),
        bubble: .init(rgb: 0x7E5FE5),
        background: .init(rgb: 0xFAF6FF)
      )
    case (.pastel, .dark):
      ThemePalette(
        accent: .init(rgb: 0x8D68C4),
        prominent: .init(rgb: 0xA35F88),
        bubble: .init(rgb: 0x6547B8),
        background: .init(rgb: 0x1E1E2E)
      )
    case (.neonNoir, .light):
      ThemePalette(
        accent: .init(rgb: 0x6C3BFF),
        prominent: .init(rgb: 0x007E88),
        bubble: .init(rgb: 0x7748FF),
        background: .init(rgb: 0xF7F6FB)
      )
    case (.neonNoir, .dark):
      ThemePalette(
        accent: .init(rgb: 0x9D6CFF),
        prominent: .init(rgb: 0x00857F),
        bubble: .init(rgb: 0x5B2FD0),
        background: .init(rgb: 0x0A0A0F)
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
