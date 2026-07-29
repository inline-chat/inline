import AppKit
import Foundation
import MacTheme
import Testing

@Suite("macOS theme palettes", .serialized)
struct ThemeTests {
  @Test("live theme colors have distinct SwiftUI identity")
  func liveThemeColorsHaveDistinctIdentity() {
    #expect(Theme.accentColor != Theme.accentColor)
    #expect(Theme.prominentColor != Theme.prominentColor)
    #expect(Theme.windowContentBackgroundColor != Theme.windowContentBackgroundColor)
    #expect(Theme.settingsWindowBackgroundColor != Theme.settingsWindowBackgroundColor)
    #expect(Theme.messageBubblePrimaryBgColor != Theme.messageBubblePrimaryBgColor)
  }

  @Test("System sidebar stays native while styled themes use translucent tint")
  func systemSidebarStaysNative() {
    let system = Theme.resolvedSidebarOverlayColor(
      preset: .system,
      variant: .light
    )
    let light = Theme.resolvedSidebarOverlayColor(
      preset: .sunset,
      variant: .light
    )
    let dark = Theme.resolvedSidebarOverlayColor(
      preset: .sunset,
      variant: .dark
    )

    #expect(system.alpha == 0)
    #expect(abs(light.alpha - 0.07) < 0.001)
    #expect(abs(dark.alpha - 0.1) < 0.001)
  }

  @Test("all presets provide distinct light and dark palettes")
  func allPresetsProvideBothVariants() {
    for preset in AppThemePreset.allCases {
      let light = palette(preset: preset, variant: .light)
      let dark = palette(preset: preset, variant: .dark)

      #expect(light != dark)
      for role in ThemeColorRole.allCases {
        #expect(light[role].alpha == 1)
        #expect(dark[role].alpha == 1)
      }
    }
  }

  @Test("default emphasis colors support their foreground and surface contexts")
  func defaultEmphasisColorsHaveUsableContrast() {
    withUserDefaults { defaults in
      for preset in AppThemePreset.allCases where preset != .system {
        for variant in ThemeAppearanceVariant.allCases {
          let palette = Theme.resolvedPalette(
            preset: preset,
            variant: variant,
            userDefaults: defaults
          )

          #expect(contrastRatio(palette.bubble, .init(rgb: 0xFFFFFF)) >= 4.5)
          #expect(contrastRatio(palette.prominent, .init(rgb: 0xFFFFFF)) >= 4.5)
          #expect(contrastRatio(palette.accent, .init(rgb: 0xFFFFFF)) >= 3)
          #expect(contrastRatio(palette.accent, palette.background) >= 3)
        }
      }
    }
  }

  @Test("Flexoki uses its canonical paper, black, and standard accent colors")
  func flexokiUsesCanonicalPalette() {
    withUserDefaults { defaults in
      #expect(
        Theme.resolvedPalette(
          preset: .flexoki,
          variant: .light,
          userDefaults: defaults
        ) == ThemePalette(
          accent: .init(rgb: 0x66800B),
          prominent: .init(rgb: 0xBC5215),
          bubble: .init(rgb: 0x205EA6),
          background: .init(rgb: 0xFFFCF0)
        )
      )
      #expect(
        Theme.resolvedPalette(
          preset: .flexoki,
          variant: .dark,
          userDefaults: defaults
        ) == ThemePalette(
          accent: .init(rgb: 0x879A39),
          prominent: .init(rgb: 0xBC5215),
          bubble: .init(rgb: 0x205EA6),
          background: .init(rgb: 0x100F0F)
        )
      )
    }
  }

  @Test("unknown stored presets fall back to System")
  func unknownPresetFallsBackToSystem() {
    withUserDefaults { defaults in
      defaults.set("removed-theme", forKey: ThemePreference.selectedPresetKey)
      #expect(ThemePreference.selectedPreset(userDefaults: defaults) == .system)
    }
  }

  @Test("System accent choices remain independent from its iMessage-like bubble")
  func systemAccentChoicesRemainIndependentFromBubble() {
    withUserDefaults { defaults in
      for variant in ThemeAppearanceVariant.allCases {
        let expectedAccent = ThemeColorValue(
          nsColor: NSColor.controlAccentColor,
          appearance: variant.nsAppearance
        )
        let expectedBubble = ThemeColorValue(rgb: variant == .light ? 0x3395FF : 0x0A84FF)
        let expectedBackground = ThemeColorValue(
          nsColor: NSColor.windowBackgroundColor,
          appearance: variant.nsAppearance
        )

        #expect(
          Theme.resolvedColor(
            role: .accent,
            preset: .system,
            variant: variant,
            userDefaults: defaults
          ) == expectedAccent
        )
        #expect(
          Theme.resolvedColor(
            role: .prominent,
            preset: .system,
            variant: variant,
            userDefaults: defaults
          ) == expectedAccent
        )
        #expect(
          Theme.resolvedColor(
            role: .bubble,
            preset: .system,
            variant: variant,
            userDefaults: defaults
          ) == expectedBubble
        )
        #expect(
          Theme.resolvedColor(
            role: .background,
            preset: .system,
            variant: variant,
            userDefaults: defaults
          ) == expectedBackground
        )
      }

      ThemePaletteOverrides.setColor(
        ThemeColorValue(rgb: 0xFF0000),
        preset: .system,
        variant: .light,
        role: .background,
        userDefaults: defaults
      )
      #expect(!ThemePaletteOverrides.hasOverrides(preset: .system, userDefaults: defaults))

      let originalBubble = Theme.resolvedColor(
        role: .bubble,
        preset: .system,
        variant: .light,
        userDefaults: defaults
      )
      defaults.set(SystemThemeAccent.purple.rawValue, forKey: ThemePreference.selectedSystemAccentKey)
      let expectedPurple = SystemThemeAccent.purple.colorValue(
        appearance: ThemeAppearanceVariant.light.nsAppearance
      )
      #expect(
        Theme.resolvedColor(
          role: .accent,
          preset: .system,
          variant: .light,
          userDefaults: defaults
        ) == expectedPurple
      )
      #expect(
        Theme.resolvedColor(
          role: .bubble,
          preset: .system,
          variant: .light,
          userDefaults: defaults
        ) == originalBubble
      )

      let customBubble = ThemeColorValue(rgb: 0x123456)
      ThemePaletteOverrides.setColor(
        customBubble,
        preset: .system,
        variant: .dark,
        role: .bubble,
        userDefaults: defaults
      )
      #expect(ThemePaletteOverrides.hasOverrides(preset: .system, userDefaults: defaults))
      #expect(
        Theme.resolvedColor(
          role: .bubble,
          preset: .system,
          variant: .dark,
          userDefaults: defaults
        ) == customBubble
      )
    }
  }

  @Test("secondary bubbles stay clean and subordinate to outgoing color")
  func secondaryBubblesStayCleanAndSubordinate() {
    withUserDefaults { defaults in
      #expect(
        Theme.resolvedSecondaryBubbleColor(
          preset: .system,
          variant: .light,
          userDefaults: defaults
        ) == ThemeColorValue(rgb: 0xECECEC)
      )

      let original = Theme.resolvedSecondaryBubbleColor(
        preset: .sunset,
        variant: .light,
        userDefaults: defaults
      )
      let midnight = Theme.resolvedSecondaryBubbleColor(
        preset: .midnight,
        variant: .light,
        userDefaults: defaults
      )
      #expect(rgbDistance(original, midnight) > 0.005)

      for preset in AppThemePreset.allCases where preset != .system {
        let page = Theme.resolvedColor(
          role: .background,
          preset: preset,
          variant: .light,
          userDefaults: defaults
        )
        let incoming = Theme.resolvedSecondaryBubbleColor(
          preset: preset,
          variant: .light,
          userDefaults: defaults
        )
        #expect(rgbDistance(incoming, page) > 0.075)
      }

      let originalBubble = Theme.resolvedColor(
        role: .bubble,
        preset: .sunset,
        variant: .light,
        userDefaults: defaults
      )
      let customBubble = ThemeColorValue(rgb: 0x123456)
      ThemePaletteOverrides.setColor(
        customBubble,
        preset: .sunset,
        variant: .light,
        role: .bubble,
        userDefaults: defaults
      )
      let customized = Theme.resolvedSecondaryBubbleColor(
        preset: .sunset,
        variant: .light,
        userDefaults: defaults
      )

      #expect(customized != original)
      #expect(customized != customBubble)
      #expect(
        rgbDistance(customized, original) <
          rgbDistance(customBubble, originalBubble) * 0.1
      )
    }
  }

  @Test("palette overrides are role-scoped, exportable, and resettable")
  func paletteOverridesRoundTrip() {
    withUserDefaults { defaults in
      let preset = AppThemePreset.sunset
      let variant = ThemeAppearanceVariant.dark
      let originalAccent = Theme.resolvedColor(
        role: .accent,
        preset: preset,
        variant: variant,
        userDefaults: defaults
      )
      let override = ThemeColorValue(rgb: 0x123456)

      ThemePaletteOverrides.setColor(
        override,
        preset: preset,
        variant: variant,
        role: .background,
        userDefaults: defaults
      )

      #expect(ThemePaletteOverrides.hasOverrides(preset: preset, userDefaults: defaults))
      #expect(ThemePaletteOverrides.customizedPresets(userDefaults: defaults) == [preset])

      #expect(
        Theme.resolvedColor(
          role: .background,
          preset: preset,
          variant: variant,
          userDefaults: defaults
        ) == override
      )
      #expect(
        Theme.resolvedColor(
          role: .accent,
          preset: preset,
          variant: variant,
          userDefaults: defaults
        ) == originalAccent
      )

      let export = ThemePaletteOverrides.export(preset: preset, userDefaults: defaults)
      #expect(export.contains("\"preset\" : \"sunset\""))
      #expect(export.contains("\"background\" : \"#123456\""))

      ThemePaletteOverrides.reset(preset: preset, variant: variant, userDefaults: defaults)
      #expect(!ThemePaletteOverrides.hasOverrides(preset: preset, userDefaults: defaults))
      #expect(
        Theme.resolvedColor(
          role: .background,
          preset: preset,
          variant: variant,
          userDefaults: defaults
        ) != override
      )
    }
  }

  @Test("exported palette files import both appearance variants")
  func paletteFileRoundTrip() throws {
    try withUserDefaults { defaults in
      let preset = AppThemePreset.midnight
      let lightAccent = ThemeColorValue(rgb: 0x123456)
      let darkBackground = ThemeColorValue(rgb: 0x0A1020)

      ThemePaletteOverrides.setColor(
        lightAccent,
        preset: preset,
        variant: .light,
        role: .accent,
        userDefaults: defaults
      )
      ThemePaletteOverrides.setColor(
        darkBackground,
        preset: preset,
        variant: .dark,
        role: .background,
        userDefaults: defaults
      )

      let data = try ThemePaletteOverrides.exportData(preset: preset, userDefaults: defaults)
      ThemePaletteOverrides.reset(preset: preset, userDefaults: defaults)

      let importedPreset = try ThemePaletteOverrides.importData(data, userDefaults: defaults)
      #expect(importedPreset == preset)
      #expect(ThemePaletteOverrides.hasOverrides(preset: preset, userDefaults: defaults))
      #expect(
        Theme.resolvedColor(
          role: .accent,
          preset: preset,
          variant: .light,
          userDefaults: defaults
        ) == lightAccent
      )
      #expect(
        Theme.resolvedColor(
          role: .background,
          preset: preset,
          variant: .dark,
          userDefaults: defaults
        ) == darkBackground
      )
    }
  }

  @Test("invalid imports preserve existing overrides")
  func invalidImportPreservesExistingOverrides() {
    withUserDefaults { defaults in
      let preset = AppThemePreset.pastel
      let existing = ThemeColorValue(rgb: 0x123456)
      ThemePaletteOverrides.setColor(
        existing,
        preset: preset,
        variant: .dark,
        role: .background,
        userDefaults: defaults
      )

      let invalidJSON = Data(
        """
        {
          "preset": "pastel",
          "light": {
            "accent": "not-a-color",
            "prominent": "#112233",
            "bubble": "#223344",
            "background": "#334455"
          },
          "dark": {
            "accent": "#445566",
            "prominent": "#556677",
            "bubble": "#667788",
            "background": "#778899"
          }
        }
        """.utf8
      )

      #expect(throws: (any Error).self) {
        try ThemePaletteOverrides.importData(invalidJSON, userDefaults: defaults)
      }
      #expect(
        Theme.resolvedColor(
          role: .background,
          preset: preset,
          variant: .dark,
          userDefaults: defaults
        ) == existing
      )
    }
  }

  private func palette(
    preset: AppThemePreset,
    variant: ThemeAppearanceVariant
  ) -> ThemePalette {
    ThemePalette(
      accent: Theme.resolvedColor(role: .accent, preset: preset, variant: variant),
      prominent: Theme.resolvedColor(role: .prominent, preset: preset, variant: variant),
      bubble: Theme.resolvedColor(role: .bubble, preset: preset, variant: variant),
      background: Theme.resolvedColor(role: .background, preset: preset, variant: variant)
    )
  }

  private func rgbDistance(_ lhs: ThemeColorValue, _ rhs: ThemeColorValue) -> Double {
    let red = lhs.red - rhs.red
    let green = lhs.green - rhs.green
    let blue = lhs.blue - rhs.blue
    return (red * red + green * green + blue * blue).squareRoot()
  }

  private func contrastRatio(_ lhs: ThemeColorValue, _ rhs: ThemeColorValue) -> Double {
    let lhsLuminance = relativeLuminance(lhs)
    let rhsLuminance = relativeLuminance(rhs)
    return (max(lhsLuminance, rhsLuminance) + 0.05) /
      (min(lhsLuminance, rhsLuminance) + 0.05)
  }

  private func relativeLuminance(_ color: ThemeColorValue) -> Double {
    func linear(_ channel: Double) -> Double {
      channel <= 0.04045
        ? channel / 12.92
        : pow((channel + 0.055) / 1.055, 2.4)
    }

    return 0.2126 * linear(color.red) +
      0.7152 * linear(color.green) +
      0.0722 * linear(color.blue)
  }

  private func withUserDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let suiteName = "ThemeTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
    try body(defaults)
  }
}
