import InlineTheme
import Testing

@Suite("Shared Apple theme catalog")
struct ThemeCatalogTests {
  @Test("all macOS presets keep their approved two-seed values")
  func approvedPaletteValues() {
    let systemCanvas = ThemeColorValue(rgb: 0xABCDEF)
    let expected: [AppThemePreset: [(ThemeAppearanceVariant, UInt32, UInt32)]] = [
      .system: [(.light, 0x00A7F8, 0xABCDEF), (.dark, 0x0A84FF, 0xABCDEF)],
      .sunset: [(.light, 0xC94D24, 0xFFF5F0), (.dark, 0xC94D24, 0x2A1A15)],
      .midnight: [(.light, 0x0969DA, 0xFFFFFF), (.dark, 0x0969DA, 0x0D1117)],
      .ash: [(.light, 0x44494D, 0xFFFFFF), (.dark, 0x44494D, 0x151516)],
      .flexoki: [(.light, 0x205EA6, 0xFFFCF0), (.dark, 0x205EA6, 0x100F0F)],
      .pastel: [(.light, 0x7D57C1, 0xE2DAF1), (.dark, 0x7D57C1, 0x292D3E)],
      .neonNoir: [(.light, 0x623BE2, 0xF7F7F7), (.dark, 0x623BE2, 0x080808)],
    ]

    for (preset, variants) in expected {
      for (variant, primary, canvas) in variants {
        let palette = ThemeCatalog.palette(
          preset: preset,
          variant: variant,
          systemCanvas: systemCanvas
        )
        #expect(palette.primary == ThemeColorValue(rgb: primary))
        #expect(palette.canvas == ThemeColorValue(rgb: canvas))
      }
    }
  }

  @Test("legacy iOS selections migrate deterministically")
  func legacyIOSMigration() {
    #expect(AppThemePreset(migratingLegacyIOSIdentifier: "Default") == .system)
    #expect(AppThemePreset(migratingLegacyIOSIdentifier: "CatppuccinMocha") == .pastel)
    #expect(AppThemePreset(migratingLegacyIOSIdentifier: "PeonyPink") == .pastel)
    #expect(AppThemePreset(migratingLegacyIOSIdentifier: "Orchid") == .pastel)
    #expect(AppThemePreset(migratingLegacyIOSIdentifier: "neon-noir") == .neonNoir)
    #expect(AppThemePreset(migratingLegacyIOSIdentifier: "unknown") == .system)
  }

  @Test("lighting vectors preserve one top-origin viewport phase")
  func viewportLightingVectors() throws {
    let top = try #require(ThemeCatalog.bubbleGradientVector(
      bubbleMinY: 0,
      bubbleHeight: 50,
      viewportMinY: 0,
      viewportHeight: 800
    ))
    let middle = try #require(ThemeCatalog.bubbleGradientVector(
      bubbleMinY: 400,
      bubbleHeight: 50,
      viewportMinY: 0,
      viewportHeight: 800
    ))
    let bottom = try #require(ThemeCatalog.bubbleGradientVector(
      bubbleMinY: 750,
      bubbleHeight: 50,
      viewportMinY: 0,
      viewportHeight: 800
    ))

    #expect(top == .init(startY: 0, endY: 16))
    #expect(middle == .init(startY: -8, endY: 8))
    #expect(bottom == .init(startY: -15, endY: 1))
    #expect(ThemeCatalog.bubbleGradientVector(
      bubbleMinY: 0,
      bubbleHeight: 0,
      viewportMinY: 0,
      viewportHeight: 800
    ) == nil)
  }

  @Test("dark lighting stays quieter than light")
  func darkLightingStrength() {
    let light = ThemeCatalog.messageBubbleGradientOverlayAlphas(variant: .light, outgoing: true)
    let darkOutgoing = ThemeCatalog.messageBubbleGradientOverlayAlphas(variant: .dark, outgoing: true)
    let darkIncoming = ThemeCatalog.messageBubbleGradientOverlayAlphas(variant: .dark, outgoing: false)

    #expect(light == .init(top: 0.26, bottom: 0.02))
    #expect(darkOutgoing.top < light.top)
    #expect(darkIncoming.top < darkOutgoing.top)
    #expect(darkIncoming.bottom < darkOutgoing.bottom)
  }
}
