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

  @Test("sidebar tint follows its independent preference")
  func sidebarTintFollowsPreference() {
    withUserDefaults { defaults in
      let system = Theme.resolvedSidebarOverlayColor(
        preset: .system,
        variant: .light,
        userDefaults: defaults
      )
      let light = Theme.resolvedSidebarOverlayColor(
        preset: .sunset,
        variant: .light,
        userDefaults: defaults
      )
      let dark = Theme.resolvedSidebarOverlayColor(
        preset: .sunset,
        variant: .dark,
        userDefaults: defaults
      )

      #expect(system.alpha == 0)
      #expect(abs(light.alpha - 0.02625) < 0.001)
      #expect(abs(dark.alpha - 0.042) < 0.001)

      defaults.set(false, forKey: ThemePreference.sidebarGlassAndTintEnabledKey)
      #expect(
        Theme.resolvedSidebarOverlayColor(
          preset: .sunset,
          variant: .light,
          userDefaults: defaults
        ).alpha == 0
      )
    }
  }

  @Test("styled window surfaces remain close to native macOS backgrounds")
  func styledWindowSurfacesAreRestrained() {
    withUserDefaults { defaults in
      for variant in ThemeAppearanceVariant.allCases {
        let native = ThemeColorValue(
          nsColor: NSColor.windowBackgroundColor,
          appearance: variant.nsAppearance
        )
        #expect(
          Theme.resolvedWindowSurfaceColor(
            preset: .system,
            variant: variant,
            userDefaults: defaults
          ) == native
        )

        for preset in AppThemePreset.allCases where preset != .system {
          let canvas = Theme.resolvedPalette(
            preset: preset,
            variant: variant,
            userDefaults: defaults
          ).canvas
          let surface = Theme.resolvedWindowSurfaceColor(
            preset: preset,
            variant: variant,
            userDefaults: defaults
          )
          let amount: CGFloat = variant == .dark ? 0.189 : 0.126
          let expectedColor = native.nsColor.blended(
            withFraction: amount,
            of: canvas.nsColor
          ) ?? native.nsColor
          let expected = ThemeColorValue(
            nsColor: expectedColor,
            appearance: variant.nsAppearance
          )
          let canvasDistance = rgbDistance(canvas, native)
          #expect(rgbDistance(surface, expected) < 0.001)
          #expect(rgbDistance(surface, native) <= canvasDistance)
          if canvasDistance > 0.001 {
            #expect(rgbDistance(surface, native) < canvasDistance)
          }
        }
      }
    }
  }

  @Test("bubble lighting is continuous and retains a soft floor")
  func bubbleLightingGradientIsContinuous() {
    #expect(abs(Theme.messageBubbleGradientOverlayAlpha(atWindowFraction: -1) - 0.25) < 0.001)
    #expect(abs(Theme.messageBubbleGradientOverlayAlpha(atWindowFraction: 0) - 0.25) < 0.001)
    #expect(abs(Theme.messageBubbleGradientOverlayAlpha(atWindowFraction: 0.5) - 0.15) < 0.001)
    #expect(abs(Theme.messageBubbleGradientOverlayAlpha(atWindowFraction: 1) - 0.05) < 0.001)
    #expect(abs(Theme.messageBubbleGradientOverlayAlpha(atWindowFraction: 2) - 0.05) < 0.001)
  }

  @Test("all semantic emphasis roles resolve from one primary seed")
  func semanticRolesSharePrimarySeed() {
    withUserDefaults { defaults in
      for preset in AppThemePreset.allCases {
        for variant in ThemeAppearanceVariant.allCases {
          let palette = Theme.resolvedPalette(
            preset: preset,
            variant: variant,
            userDefaults: defaults
          )
          #expect(palette.accent == palette.primary)
          #expect(palette.prominent == palette.primary)
          #expect(palette.bubble == palette.primary)
          #expect(palette.background == palette.canvas)
          #expect(palette.primary.alpha == 1)
          #expect(palette.canvas.alpha == 1)
        }
      }
    }
  }

  @Test("all presets provide distinct light and dark palettes")
  func allPresetsProvideBothVariants() {
    withUserDefaults { defaults in
      for preset in AppThemePreset.allCases {
        let light = Theme.resolvedPalette(
          preset: preset,
          variant: .light,
          userDefaults: defaults
        )
        let dark = Theme.resolvedPalette(
          preset: preset,
          variant: .dark,
          userDefaults: defaults
        )
        #expect(light != dark)
      }
    }
  }

  @Test("default primary colors support white content and canvas separation")
  func defaultPrimaryColorsHaveUsableContrast() {
    withUserDefaults { defaults in
      for preset in AppThemePreset.allCases where preset != .system {
        for variant in ThemeAppearanceVariant.allCases {
          let palette = Theme.resolvedPalette(
            preset: preset,
            variant: variant,
            userDefaults: defaults
          )
          #expect(contrastRatio(palette.primary, .init(rgb: 0xFFFFFF)) >= 4.5)
          #expect(contrastRatio(palette.primary, palette.canvas) >= 1.8)
        }
      }
    }
  }

  @Test("sourced palettes retain their published primary and canvas pairs")
  func sourcedPalettesRetainPublishedPairs() {
    withUserDefaults { defaults in
      #expect(
        Theme.resolvedPalette(
          preset: .sunset,
          variant: .light,
          userDefaults: defaults
        ) == ThemePalette(primary: .init(rgb: 0xC94D24), canvas: .init(rgb: 0xFFF5F0))
      )
      #expect(
        Theme.resolvedPalette(
          preset: .midnight,
          variant: .dark,
          userDefaults: defaults
        ) == ThemePalette(primary: .init(rgb: 0x0969DA), canvas: .init(rgb: 0x0D1117))
      )
      #expect(
        Theme.resolvedPalette(
          preset: .ash,
          variant: .light,
          userDefaults: defaults
        ) == ThemePalette(primary: .init(rgb: 0x44494D), canvas: .init(rgb: 0xFFFFFF))
      )
      #expect(
        Theme.resolvedPalette(
          preset: .flexoki,
          variant: .light,
          userDefaults: defaults
        ) == ThemePalette(primary: .init(rgb: 0x205EA6), canvas: .init(rgb: 0xFFFCF0))
      )
      #expect(
        Theme.resolvedPalette(
          preset: .pastel,
          variant: .dark,
          userDefaults: defaults
        ) == ThemePalette(primary: .init(rgb: 0x7D57C1), canvas: .init(rgb: 0x292D3E))
      )
      #expect(
        Theme.resolvedPalette(
          preset: .neonNoir,
          variant: .dark,
          userDefaults: defaults
        ) == ThemePalette(primary: .init(rgb: 0x623BE2), canvas: .init(rgb: 0x080808))
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

  @Test("System uses one iMessage primary and native canvas")
  func systemUsesOnePrimaryAndNativeCanvas() {
    withUserDefaults { defaults in
      for variant in ThemeAppearanceVariant.allCases {
        let expectedPrimary = ThemeColorValue(rgb: variant == .light ? 0x00A7F8 : 0x0A84FF)
        let expectedCanvas = ThemeColorValue(
          nsColor: NSColor.windowBackgroundColor,
          appearance: variant.nsAppearance
        )
        let palette = Theme.resolvedPalette(
          preset: .system,
          variant: variant,
          userDefaults: defaults
        )
        #expect(palette.primary == expectedPrimary)
        #expect(palette.canvas == expectedCanvas)
      }

      defaults.set("purple", forKey: ThemePreference.selectedSystemAccentKey)
      #expect(
        Theme.resolvedPalette(
          preset: .system,
          variant: .light,
          userDefaults: defaults
        ).primary == ThemeColorValue(rgb: 0x00A7F8)
      )

      ThemePaletteOverrides.setColor(
        .init(rgb: 0xFF0000),
        preset: .system,
        variant: .light,
        role: .canvas,
        userDefaults: defaults
      )
      #expect(!ThemePaletteOverrides.hasOverrides(preset: .system, userDefaults: defaults))

      let customPrimary = ThemeColorValue(rgb: 0x123456)
      ThemePaletteOverrides.setColor(
        customPrimary,
        preset: .system,
        variant: .dark,
        role: .primary,
        userDefaults: defaults
      )
      #expect(ThemePaletteOverrides.hasOverrides(preset: .system, userDefaults: defaults))
      #expect(
        Theme.resolvedPalette(
          preset: .system,
          variant: .dark,
          userDefaults: defaults
        ).primary == customPrimary
      )
    }
  }

  @Test("secondary bubbles stay clean and subordinate to primary")
  func secondaryBubblesStayCleanAndSubordinate() {
    withUserDefaults { defaults in
      #expect(
        Theme.resolvedSecondaryBubbleColor(
          preset: .system,
          variant: .light,
          userDefaults: defaults
        ) == ThemeColorValue(rgb: 0xECECEC)
      )

      for preset in AppThemePreset.allCases where preset != .system {
        let page = Theme.resolvedPalette(
          preset: preset,
          variant: .light,
          userDefaults: defaults
        ).canvas
        let incoming = Theme.resolvedSecondaryBubbleColor(
          preset: preset,
          variant: .light,
          userDefaults: defaults
        )
        let lightAtWindowTop = ThemeColorValue(
          nsColor: incoming.nsColor.blended(
            withFraction: Theme.messageBubbleGradientTopOverlayAlpha,
            of: .white
          ) ?? incoming.nsColor,
          appearance: ThemeAppearanceVariant.light.nsAppearance
        )
        #expect(
          rgbDistance(incoming, page) > 0.075,
          "Incoming bubble blends into \(preset.title)"
        )
        #expect(contrastRatio(lightAtWindowTop, .init(rgb: 0x000000)) >= 4.5)

        let darkIncoming = Theme.resolvedSecondaryBubbleColor(
          preset: preset,
          variant: .dark,
          userDefaults: defaults
        )
        let darkAtWindowTop = ThemeColorValue(
          nsColor: darkIncoming.nsColor.blended(
            withFraction: Theme.messageBubbleGradientTopOverlayAlpha,
            of: .white
          ) ?? darkIncoming.nsColor,
          appearance: ThemeAppearanceVariant.dark.nsAppearance
        )
        #expect(darkIncoming == ThemeColorValue(rgb: 0x3A3A3A))
        #expect(contrastRatio(darkAtWindowTop, .init(rgb: 0xFFFFFF)) >= 4.5)
      }

      let original = Theme.resolvedSecondaryBubbleColor(
        preset: .sunset,
        variant: .light,
        userDefaults: defaults
      )
      ThemePaletteOverrides.setColor(
        .init(rgb: 0x123456),
        preset: .sunset,
        variant: .light,
        role: .primary,
        userDefaults: defaults
      )
      let customized = Theme.resolvedSecondaryBubbleColor(
        preset: .sunset,
        variant: .light,
        userDefaults: defaults
      )
      #expect(customized == original)

      let originalDark = Theme.resolvedSecondaryBubbleColor(
        preset: .sunset,
        variant: .dark,
        userDefaults: defaults
      )
      ThemePaletteOverrides.setColor(
        .init(rgb: 0x654321),
        preset: .sunset,
        variant: .dark,
        role: .canvas,
        userDefaults: defaults
      )
      #expect(
        Theme.resolvedSecondaryBubbleColor(
          preset: .sunset,
          variant: .dark,
          userDefaults: defaults
        ) == originalDark
      )
    }
  }

  @Test("two-seed overrides are scoped, exportable, and resettable")
  func paletteOverridesRoundTrip() {
    withUserDefaults { defaults in
      let preset = AppThemePreset.sunset
      let variant = ThemeAppearanceVariant.dark
      let originalPrimary = Theme.resolvedPalette(
        preset: preset,
        variant: variant,
        userDefaults: defaults
      ).primary
      let override = ThemeColorValue(rgb: 0x123456)

      ThemePaletteOverrides.setColor(
        override,
        preset: preset,
        variant: variant,
        role: .canvas,
        userDefaults: defaults
      )

      #expect(ThemePaletteOverrides.customizedPresets(userDefaults: defaults) == [preset])
      let customized = Theme.resolvedPalette(
        preset: preset,
        variant: variant,
        userDefaults: defaults
      )
      #expect(customized.canvas == override)
      #expect(customized.primary == originalPrimary)

      let export = ThemePaletteOverrides.export(preset: preset, userDefaults: defaults)
      #expect(export.contains("\"version\" : 2"))
      #expect(export.contains("\"canvas\" : \"#123456\""))
      #expect(!export.contains("\"accent\""))

      ThemePaletteOverrides.reset(preset: preset, variant: variant, userDefaults: defaults)
      #expect(!ThemePaletteOverrides.hasOverrides(preset: preset, userDefaults: defaults))
    }
  }

  @Test("v2 palette files import both appearance variants")
  func paletteFileRoundTrip() throws {
    try withUserDefaults { defaults in
      let preset = AppThemePreset.midnight
      let lightPrimary = ThemeColorValue(rgb: 0x123456)
      let darkCanvas = ThemeColorValue(rgb: 0x0A1020)
      ThemePaletteOverrides.setColor(
        lightPrimary,
        preset: preset,
        variant: .light,
        role: .primary,
        userDefaults: defaults
      )
      ThemePaletteOverrides.setColor(
        darkCanvas,
        preset: preset,
        variant: .dark,
        role: .canvas,
        userDefaults: defaults
      )

      let data = try ThemePaletteOverrides.exportData(preset: preset, userDefaults: defaults)
      ThemePaletteOverrides.reset(preset: preset, userDefaults: defaults)
      let importedPreset = try ThemePaletteOverrides.importData(data, userDefaults: defaults)
      #expect(importedPreset == preset)

      let light = Theme.resolvedPalette(
        preset: preset,
        variant: .light,
        userDefaults: defaults
      )
      let dark = Theme.resolvedPalette(
        preset: preset,
        variant: .dark,
        userDefaults: defaults
      )
      #expect(light.primary == lightPrimary)
      #expect(dark.canvas == darkCanvas)
    }
  }

  @Test("v1 palette files migrate bubble and background")
  func v1PaletteFilesMigrate() throws {
    try withUserDefaults { defaults in
      let data = Data(
        """
        {
          "preset": "pastel",
          "light": {
            "accent": "#111111",
            "prominent": "#222222",
            "bubble": "#334455",
            "background": "#F0F1F2"
          },
          "dark": {
            "accent": "#333333",
            "prominent": "#444444",
            "bubble": "#556677",
            "background": "#101112"
          }
        }
        """.utf8
      )

      let importedPreset = try ThemePaletteOverrides.importData(data, userDefaults: defaults)
      #expect(importedPreset == .pastel)
      let light = Theme.resolvedPalette(
        preset: .pastel,
        variant: .light,
        userDefaults: defaults
      )
      #expect(light.primary == ThemeColorValue(rgb: 0x334455))
      #expect(light.canvas == ThemeColorValue(rgb: 0xF0F1F2))
    }
  }

  @Test("legacy local overrides migrate once without deleting old storage")
  func legacyOverridesMigrateOnce() throws {
    try withUserDefaults { defaults in
      let bubble = ThemeColorValue(rgb: 0x123456)
      let background = ThemeColorValue(rgb: 0xF1F2F3)
      let legacy = LegacyStorage(colors: [
        "sunset.light.accent": .init(rgb: 0x111111),
        "sunset.light.prominent": .init(rgb: 0x222222),
        "sunset.light.bubble": bubble,
        "sunset.light.background": background,
      ])
      defaults.set(
        try JSONEncoder().encode(legacy),
        forKey: ThemePaletteOverrides.legacyStorageKey
      )

      let palette = Theme.resolvedPalette(
        preset: .sunset,
        variant: .light,
        userDefaults: defaults
      )
      #expect(palette.primary == bubble)
      #expect(palette.canvas == background)
      #expect(defaults.bool(forKey: ThemePaletteOverrides.legacyMigrationKey))
      #expect(defaults.data(forKey: ThemePaletteOverrides.legacyStorageKey) != nil)
    }
  }

  @Test("invalid imports preserve existing overrides")
  func invalidImportPreservesExistingOverrides() {
    withUserDefaults { defaults in
      let existing = ThemeColorValue(rgb: 0x123456)
      ThemePaletteOverrides.setColor(
        existing,
        preset: .pastel,
        variant: .dark,
        role: .canvas,
        userDefaults: defaults
      )
      let invalidJSON = Data(
        """
        {
          "version": 2,
          "preset": "pastel",
          "light": { "primary": "not-a-color", "canvas": "#334455" },
          "dark": { "primary": "#667788", "canvas": "#778899" }
        }
        """.utf8
      )

      #expect(throws: (any Error).self) {
        try ThemePaletteOverrides.importData(invalidJSON, userDefaults: defaults)
      }
      #expect(
        Theme.resolvedPalette(
          preset: .pastel,
          variant: .dark,
          userDefaults: defaults
        ).canvas == existing
      )
    }
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

private struct LegacyStorage: Codable {
  var colors: [String: ThemeColorValue]
}
