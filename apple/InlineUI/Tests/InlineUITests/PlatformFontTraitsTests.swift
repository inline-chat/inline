#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Testing
@testable import TextProcessing

@Suite("PlatformFontTraits")
@MainActor
struct PlatformFontTraitsTests {
  @Test("settingBold adds bold while keeping point size")
  func settingBoldAddsTrait() {
    let font = PlatformFont.systemFont(ofSize: 14)

    let result = PlatformFontTraits.settingBold(true, on: font)

    #expect(PlatformFontTraits.isBold(result))
    #expect(result.pointSize == font.pointSize)
  }

  @Test("settingBold removes bold while keeping point size")
  func settingBoldRemovesTrait() {
    let font = PlatformFontTraits.settingBold(true, on: PlatformFont.systemFont(ofSize: 14))

    let result = PlatformFontTraits.settingBold(false, on: font)

    #expect(PlatformFontTraits.isBold(font))
    #expect(!PlatformFontTraits.isBold(result))
    #expect(result.pointSize == font.pointSize)
  }

  @Test("settingBold preserves fixed-pitch fonts when available")
  func settingBoldPreservesFixedPitch() {
    let font = PlatformFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    let bold = PlatformFontTraits.settingBold(true, on: font)
    let unbold = PlatformFontTraits.settingBold(false, on: bold)

    #expect(isFixedPitch(font))
    #expect(isFixedPitch(bold))
    #expect(isFixedPitch(unbold))
  }

  @Test("block typography preserves inline emphasis, code, and non-font attributes")
  func baseFontPreservesInlineStyles() throws {
    let text = NSMutableAttributedString(string: "plain italic bold code")
    let original = PlatformFont.systemFont(ofSize: 14)
    text.addAttribute(.font, value: original, range: NSRange(location: 0, length: text.length))
    text.addAttribute(.font, value: italic(original), range: NSRange(location: 6, length: 6))
    text.addAttribute(.font, value: PlatformFontTraits.settingBold(true, on: original),
                      range: NSRange(location: 13, length: 4))
    text.addAttribute(.font, value: italic(.monospacedSystemFont(ofSize: 12, weight: .regular)),
                      range: NSRange(location: 18, length: 4))
    text.addAttribute(.link, value: "https://example.com", range: NSRange(location: 6, length: 6))
    text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                      range: NSRange(location: 13, length: 4))
    let base = PlatformFont.systemFont(ofSize: 22, weight: .medium)

    PlatformFontTraits.applyBaseFont(base, to: text)

    #expect(text.string == "plain italic bold code")
    let plain = try font(in: text, at: 0)
    #expect(plain.pointSize == 22)
    #expect(!isItalic(plain))
    #expect(!isFixedPitch(plain))
    #expect(isItalic(try font(in: text, at: 6)))
    #expect(PlatformFontTraits.isBold(try font(in: text, at: 13)))
    let code = try font(in: text, at: 18)
    #expect(isFixedPitch(code))
    #expect(isItalic(code))
    for offset in [6, 13, 18] {
      #expect(try font(in: text, at: offset).pointSize == 22)
    }
    #expect(text.attribute(.link, at: 6, effectiveRange: nil) as? String == "https://example.com")
    #expect(text.attribute(.underlineStyle, at: 13, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
  }

  @Test("bold heading typography also applies to inline code")
  func boldBaseAppliesToCode() throws {
    let text = NSMutableAttributedString(
      string: "code", attributes: [.font: PlatformFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
    )
    PlatformFontTraits.applyBaseFont(.boldSystemFont(ofSize: 24), to: text)
    let result = try font(in: text, at: 0)
    #expect(isFixedPitch(result))
    #expect(PlatformFontTraits.isBold(result))
    #expect(result.pointSize == 24)
  }

  @Test("block typography handles empty text and missing font attributes")
  func baseFontHandlesUnstyledText() throws {
    let base = PlatformFont.systemFont(ofSize: 18, weight: .medium)
    let empty = NSMutableAttributedString(string: "")
    PlatformFontTraits.applyBaseFont(base, to: empty)
    #expect(empty.length == 0)

    let text = NSMutableAttributedString(string: "unstyled")
    PlatformFontTraits.applyBaseFont(base, to: text)
    #expect(try font(in: text, at: 0) == base)
  }

  @Test("medium and semibold block fonts keep inline bold contrast and code weight")
  func baseFontPreservesNumericWeights() throws {
    for weight in [PlatformFontWeight.medium, .semibold] {
      let base = PlatformFont.systemFont(ofSize: 20, weight: weight)
      let text = NSMutableAttributedString(string: "bold code tilted")
      text.addAttribute(.font, value: PlatformFont.boldSystemFont(ofSize: 14),
                        range: NSRange(location: 0, length: 4))
      text.addAttribute(.font, value: PlatformFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                        range: NSRange(location: 5, length: 4))
      text.addAttribute(.font, value: italic(.monospacedSystemFont(ofSize: 12, weight: .regular)),
                        range: NSRange(location: 10, length: 6))
      PlatformFontTraits.applyBaseFont(base, to: text)

      #expect(try numericWeight(font(in: text, at: 0)) >= Double(PlatformFontWeight.bold.rawValue) - 0.01)
      #expect(try abs(numericWeight(font(in: text, at: 5)) - numericWeight(base)) < 0.01)
      let tilted = try font(in: text, at: 10)
      #expect(isFixedPitch(tilted))
      #expect(isItalic(tilted))
      #expect(abs(numericWeight(tilted) - numericWeight(base)) < 0.01)
    }
  }

  private func font(in text: NSAttributedString, at offset: Int) throws -> PlatformFont {
    try #require(text.attribute(.font, at: offset, effectiveRange: nil) as? PlatformFont)
  }

  private func numericWeight(_ font: PlatformFont) -> Double {
    #if os(macOS)
    let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
    #else
    let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
    #endif
    return (traits?[.weight] as? NSNumber)?.doubleValue ?? 0
  }

  private func italic(_ font: PlatformFont) -> PlatformFont {
    #if os(macOS)
    NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    #else
    UIFont(descriptor: font.fontDescriptor.withSymbolicTraits(
      font.fontDescriptor.symbolicTraits.union(.traitItalic)
    )!, size: font.pointSize)
    #endif
  }

  private func isItalic(_ font: PlatformFont) -> Bool {
    #if os(macOS)
    NSFontManager.shared.traits(of: font).contains(.italicFontMask)
    #else
    font.fontDescriptor.symbolicTraits.contains(.traitItalic)
    #endif
  }

  private func isFixedPitch(_ font: PlatformFont) -> Bool {
    #if os(macOS)
    NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask)
    #else
    font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
    #endif
  }
}
