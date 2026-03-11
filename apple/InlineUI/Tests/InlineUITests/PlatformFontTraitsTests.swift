#if canImport(AppKit)
import AppKit
import Testing
@testable import TextProcessing

@Suite("PlatformFontTraits")
struct PlatformFontTraitsTests {
  @Test("settingBold adds bold while keeping point size")
  func settingBoldAddsTrait() {
    let font = NSFont.systemFont(ofSize: 14)

    let result = PlatformFontTraits.settingBold(true, on: font)

    #expect(PlatformFontTraits.isBold(result))
    #expect(result.pointSize == font.pointSize)
  }

  @Test("settingBold removes bold while keeping point size")
  func settingBoldRemovesTrait() {
    let font = PlatformFontTraits.settingBold(true, on: NSFont.systemFont(ofSize: 14))

    let result = PlatformFontTraits.settingBold(false, on: font)

    #expect(PlatformFontTraits.isBold(font))
    #expect(!PlatformFontTraits.isBold(result))
    #expect(result.pointSize == font.pointSize)
  }

  @Test("settingBold preserves fixed-pitch fonts when available")
  func settingBoldPreservesFixedPitch() {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    let bold = PlatformFontTraits.settingBold(true, on: font)
    let unbold = PlatformFontTraits.settingBold(false, on: bold)

    #expect(isFixedPitch(font))
    #expect(isFixedPitch(bold))
    #expect(isFixedPitch(unbold))
  }

  private func isFixedPitch(_ font: NSFont) -> Bool {
    NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask)
  }
}
#endif
