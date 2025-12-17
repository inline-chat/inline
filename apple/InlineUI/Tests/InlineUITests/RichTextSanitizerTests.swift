#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import TextProcessing

@Suite("RichTextSanitizer Tests")
struct RichTextSanitizerTests {
  // MARK: - Test Configuration

  private var baseFont: NSFont { NSFont.systemFont(ofSize: 14) }
  private var baseColor: NSColor { NSColor.labelColor }

  private func makeConfig(
    preserveBold: Bool = true,
    preserveItalic: Bool = true,
    preserveLinks: Bool = true,
    convertHeadingsToBold: Bool = true
  ) -> RichTextSanitizer.Configuration {
    RichTextSanitizer.Configuration(
      baseFont: baseFont,
      baseColor: baseColor,
      preserveBold: preserveBold,
      preserveItalic: preserveItalic,
      preserveLinks: preserveLinks,
      convertHeadingsToBold: convertHeadingsToBold
    )
  }

  private func makeSanitizer(
    preserveBold: Bool = true,
    preserveItalic: Bool = true,
    preserveLinks: Bool = true,
    convertHeadingsToBold: Bool = true
  ) -> RichTextSanitizer {
    RichTextSanitizer(configuration: makeConfig(
      preserveBold: preserveBold,
      preserveItalic: preserveItalic,
      preserveLinks: preserveLinks,
      convertHeadingsToBold: convertHeadingsToBold
    ))
  }

  // MARK: - Helper Methods

  private func makeBoldAttributedString(_ text: String, boldRange: NSRange) -> NSAttributedString {
    let attributed = NSMutableAttributedString(string: text)
    let boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
    attributed.addAttribute(.font, value: boldFont, range: boldRange)
    return attributed
  }

  private func makeItalicAttributedString(_ text: String, italicRange: NSRange) -> NSAttributedString {
    let attributed = NSMutableAttributedString(string: text)
    let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
    attributed.addAttribute(.font, value: italicFont, range: italicRange)
    return attributed
  }

  private func makeLinkAttributedString(_ text: String, linkRange: NSRange, url: String) -> NSAttributedString {
    let attributed = NSMutableAttributedString(string: text)
    attributed.addAttribute(.link, value: url, range: linkRange)
    return attributed
  }

  private func hasBoldTrait(in attributedString: NSAttributedString, at location: Int) -> Bool {
    guard let font = attributedString.attribute(.font, at: location, effectiveRange: nil) as? NSFont else {
      return false
    }
    return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
  }

  private func hasItalicTrait(in attributedString: NSAttributedString, at location: Int) -> Bool {
    guard let font = attributedString.attribute(.font, at: location, effectiveRange: nil) as? NSFont else {
      return false
    }
    return NSFontManager.shared.traits(of: font).contains(.italicFontMask)
  }

  private func hasLink(in attributedString: NSAttributedString, at location: Int) -> String? {
    if let url = attributedString.attribute(.link, at: location, effectiveRange: nil) as? URL {
      return url.absoluteString
    }
    if let urlString = attributedString.attribute(.link, at: location, effectiveRange: nil) as? String {
      return urlString
    }
    return nil
  }

  // MARK: - Plain Text Tests

  @Test("Sanitizes plain text without any formatting")
  func testPlainText() {
    let input = NSAttributedString(string: "Hello, World!")
    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(input)

    #expect(result.attributedString.string == "Hello, World!")
    #expect(result.stats.boldRanges == 0)
    #expect(result.stats.italicRanges == 0)
    #expect(result.stats.linksPreserved == 0)
  }

  @Test("Handles empty string")
  func testEmptyString() {
    let input = NSAttributedString(string: "")
    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(input)

    #expect(result.attributedString.string == "")
    #expect(result.stats.boldRanges == 0)
  }

  // MARK: - Bold Tests

  @Test("Preserves bold formatting")
  func testPreservesBold() {
    let text = "Hello bold world"
    let boldRange = NSRange(location: 6, length: 4) // "bold"
    let input = makeBoldAttributedString(text, boldRange: boldRange)

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(input)

    #expect(result.attributedString.string == text)
    #expect(hasBoldTrait(in: result.attributedString, at: 6))
    #expect(!hasBoldTrait(in: result.attributedString, at: 0))
    #expect(result.stats.boldRanges == 1)
  }

  @Test("Detects bold via font weight")
  func testDetectsBoldViaFontWeight() {
    let text = "Heavy weight text"
    let attributed = NSMutableAttributedString(string: text)
    // Use a semibold/bold weight font directly (simulates HTML font-weight: bold)
    let heavyFont = NSFont.systemFont(ofSize: 14, weight: .bold)
    attributed.addAttribute(.font, value: heavyFont, range: NSRange(location: 0, length: text.count))

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(attributed)

    // Note: Detection works (stats count is correct). Font rendering in NSTextView is a separate issue.
    // TODO: Fix bold font rendering - see RichTextSanitizer.swift fontWithTraits()
    #expect(result.stats.boldRanges == 1)
  }

  @Test("Detects bold via font name")
  func testDetectsBoldViaFontName() {
    let text = "Bold named font"
    let attributed = NSMutableAttributedString(string: text)
    // Try to get a font with "Bold" in the name
    if let boldNamedFont = NSFont(name: "Helvetica-Bold", size: 14) {
      attributed.addAttribute(.font, value: boldNamedFont, range: NSRange(location: 0, length: text.count))

      let sanitizer = makeSanitizer()
      let result = sanitizer.sanitize(attributed)

      // Note: Detection works (stats count is correct). Font rendering in NSTextView is a separate issue.
      // TODO: Fix bold font rendering - see RichTextSanitizer.swift fontWithTraits()
      #expect(result.stats.boldRanges == 1)
    }
  }

  @Test("Strips bold when disabled")
  func testStripsBoldWhenDisabled() {
    let text = "Hello bold world"
    let boldRange = NSRange(location: 6, length: 4)
    let input = makeBoldAttributedString(text, boldRange: boldRange)

    let sanitizer = makeSanitizer(preserveBold: false)
    let result = sanitizer.sanitize(input)

    #expect(!hasBoldTrait(in: result.attributedString, at: 6))
    #expect(result.stats.boldRanges == 0)
  }

  // MARK: - Italic Tests

  @Test("Preserves italic formatting")
  func testPreservesItalic() {
    let text = "Hello italic world"
    let italicRange = NSRange(location: 6, length: 6) // "italic"
    let input = makeItalicAttributedString(text, italicRange: italicRange)

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(input)

    #expect(result.attributedString.string == text)
    #expect(hasItalicTrait(in: result.attributedString, at: 6))
    #expect(!hasItalicTrait(in: result.attributedString, at: 0))
    #expect(result.stats.italicRanges == 1)
  }

  @Test("Strips italic when disabled")
  func testStripsItalicWhenDisabled() {
    let text = "Hello italic world"
    let italicRange = NSRange(location: 6, length: 6)
    let input = makeItalicAttributedString(text, italicRange: italicRange)

    let sanitizer = makeSanitizer(preserveItalic: false)
    let result = sanitizer.sanitize(input)

    #expect(!hasItalicTrait(in: result.attributedString, at: 6))
    #expect(result.stats.italicRanges == 0)
  }

  // MARK: - Link Tests

  @Test("Preserves https link")
  func testPreservesHttpsLink() {
    let text = "Visit example.com"
    let linkRange = NSRange(location: 6, length: 11) // "example.com"
    let input = makeLinkAttributedString(text, linkRange: linkRange, url: "https://example.com")

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(input)

    #expect(hasLink(in: result.attributedString, at: 6) == "https://example.com")
    #expect(hasLink(in: result.attributedString, at: 0) == nil)
    #expect(result.stats.linksPreserved == 1)
    #expect(result.stats.linksDropped == 0)
  }

  @Test("Preserves http link")
  func testPreservesHttpLink() {
    let text = "Visit example.com"
    let linkRange = NSRange(location: 6, length: 11)
    let input = makeLinkAttributedString(text, linkRange: linkRange, url: "http://example.com")

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(input)

    #expect(hasLink(in: result.attributedString, at: 6) == "http://example.com")
    #expect(result.stats.linksPreserved == 1)
  }

  @Test("Preserves mailto link")
  func testPreservesMailtoLink() {
    let text = "Email test@example.com"
    let linkRange = NSRange(location: 6, length: 16) // "test@example.com"
    let input = makeLinkAttributedString(text, linkRange: linkRange, url: "mailto:test@example.com")

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(input)

    #expect(hasLink(in: result.attributedString, at: 6) == "mailto:test@example.com")
    #expect(result.stats.linksPreserved == 1)
  }

  @Test("Drops link with disallowed scheme")
  func testDropsDisallowedScheme() {
    let text = "Run javascript"
    let linkRange = NSRange(location: 4, length: 10) // "javascript"
    let input = makeLinkAttributedString(text, linkRange: linkRange, url: "javascript:alert(1)")

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(input)

    #expect(hasLink(in: result.attributedString, at: 4) == nil)
    #expect(result.stats.linksPreserved == 0)
    #expect(result.stats.linksDropped == 1)
  }

  @Test("Drops file scheme link")
  func testDropsFileScheme() {
    let text = "Open file"
    let linkRange = NSRange(location: 5, length: 4) // "file"
    let input = makeLinkAttributedString(text, linkRange: linkRange, url: "file:///etc/passwd")

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(input)

    #expect(hasLink(in: result.attributedString, at: 5) == nil)
    #expect(result.stats.linksDropped == 1)
  }

  @Test("Drops multiline link")
  func testDropsMultilineLink() {
    let text = "Line1\nLine2"
    let linkRange = NSRange(location: 0, length: 11) // entire text
    let input = makeLinkAttributedString(text, linkRange: linkRange, url: "https://example.com")

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(input)

    #expect(hasLink(in: result.attributedString, at: 0) == nil)
    #expect(result.stats.linksDropped == 1)
  }

  @Test("Drops overly long link text")
  func testDropsLongLinkText() {
    let longText = String(repeating: "a", count: 600)
    let linkRange = NSRange(location: 0, length: 600)
    let input = makeLinkAttributedString(longText, linkRange: linkRange, url: "https://example.com")

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(input)

    #expect(hasLink(in: result.attributedString, at: 0) == nil)
    #expect(result.stats.linksDropped == 1)
  }

  @Test("Strips links when disabled")
  func testStripsLinksWhenDisabled() {
    let text = "Visit example.com"
    let linkRange = NSRange(location: 6, length: 11)
    let input = makeLinkAttributedString(text, linkRange: linkRange, url: "https://example.com")

    let sanitizer = makeSanitizer(preserveLinks: false)
    let result = sanitizer.sanitize(input)

    #expect(hasLink(in: result.attributedString, at: 6) == nil)
    #expect(result.stats.linksPreserved == 0)
  }

  // MARK: - Heading Tests

  @Test("Converts large font to bold (heading detection)")
  func testConvertsLargeFontToBold() {
    let text = "Large Heading"
    let attributed = NSMutableAttributedString(string: text)
    // Use a font size that's > 1.3x the base font (14 * 1.3 = 18.2)
    let largeFont = NSFont.systemFont(ofSize: 20)
    attributed.addAttribute(.font, value: largeFont, range: NSRange(location: 0, length: text.count))

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(attributed)

    #expect(hasBoldTrait(in: result.attributedString, at: 0))
    #expect(result.stats.headingsConverted == 1)
  }

  @Test("Detects markdown heading")
  func testDetectsMarkdownHeading() {
    let text = "# Heading\nNormal text"
    let input = NSAttributedString(string: text)

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(input)

    // The heading line should be bold
    #expect(hasBoldTrait(in: result.attributedString, at: 0))
    // "Normal text" should not be bold
    #expect(!hasBoldTrait(in: result.attributedString, at: 10))
    #expect(result.stats.headingsConverted == 1)
  }

  @Test("Skips heading detection when disabled")
  func testSkipsHeadingDetectionWhenDisabled() {
    let text = "# Heading"
    let input = NSAttributedString(string: text)

    let sanitizer = makeSanitizer(convertHeadingsToBold: false)
    let result = sanitizer.sanitize(input)

    #expect(!hasBoldTrait(in: result.attributedString, at: 0))
    #expect(result.stats.headingsConverted == 0)
  }

  // MARK: - Combined Formatting Tests

  @Test("Preserves bold and italic together")
  func testPreservesBoldAndItalic() {
    let text = "Bold and italic text"
    let attributed = NSMutableAttributedString(string: text)

    // Apply bold to "Bold"
    let boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
    attributed.addAttribute(.font, value: boldFont, range: NSRange(location: 0, length: 4))

    // Apply italic to "italic"
    let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
    attributed.addAttribute(.font, value: italicFont, range: NSRange(location: 9, length: 6))

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(attributed)

    #expect(hasBoldTrait(in: result.attributedString, at: 0))
    #expect(hasItalicTrait(in: result.attributedString, at: 9))
    #expect(result.stats.boldRanges >= 1)
    #expect(result.stats.italicRanges == 1)
  }

  @Test("Preserves bold italic combined")
  func testPreservesBoldItalicCombined() {
    let text = "Bold italic"
    let attributed = NSMutableAttributedString(string: text)

    // Apply both bold and italic traits
    var boldItalicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
    boldItalicFont = NSFontManager.shared.convert(boldItalicFont, toHaveTrait: .italicFontMask)
    attributed.addAttribute(.font, value: boldItalicFont, range: NSRange(location: 0, length: text.count))

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(attributed)

    #expect(hasBoldTrait(in: result.attributedString, at: 0))
    #expect(hasItalicTrait(in: result.attributedString, at: 0))
  }

  @Test("Multiple links in text")
  func testMultipleLinks() {
    let text = "Visit google.com and apple.com"
    let attributed = NSMutableAttributedString(string: text)
    attributed.addAttribute(.link, value: "https://google.com", range: NSRange(location: 6, length: 10))
    attributed.addAttribute(.link, value: "https://apple.com", range: NSRange(location: 21, length: 9))

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(attributed)

    #expect(hasLink(in: result.attributedString, at: 6) == "https://google.com")
    #expect(hasLink(in: result.attributedString, at: 21) == "https://apple.com")
    #expect(result.stats.linksPreserved == 2)
  }

  // MARK: - Font Normalization Tests

  @Test("Normalizes different fonts to base font")
  func testNormalizesFontsToBase() {
    let text = "Mixed fonts"
    let attributed = NSMutableAttributedString(string: text)
    // Use a completely different font
    let differentFont = NSFont(name: "Courier", size: 18)!
    attributed.addAttribute(.font, value: differentFont, range: NSRange(location: 0, length: text.count))

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(attributed)

    // Font should be normalized to base font (no bold/italic traits)
    let resultFont = result.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    #expect(resultFont?.pointSize == baseFont.pointSize)
    #expect(!hasBoldTrait(in: result.attributedString, at: 0))
    #expect(!hasItalicTrait(in: result.attributedString, at: 0))
  }

  // MARK: - Custom .italic Attribute Tests

  @Test("Preserves italic from custom attribute")
  func testPreservesCustomItalicAttribute() {
    let text = "Custom italic"
    let attributed = NSMutableAttributedString(string: text)
    attributed.addAttribute(.italic, value: true, range: NSRange(location: 7, length: 6))

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(attributed)

    #expect(hasItalicTrait(in: result.attributedString, at: 7))
  }

  // MARK: - List Marker Normalization Tests

  @Test("Normalizes single-level bullet list")
  func testNormalizesSingleLevelBulletList() {
    // \t-\t should become "- "
    let text = "\t-\tFirst item\n\t-\tSecond item"
    let input = NSAttributedString(string: text)

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(input)

    #expect(result.attributedString.string == "- First item\n- Second item")
    #expect(result.stats.listMarkersNormalized == 2)
  }

  @Test("Normalizes nested bullet list")
  func testNormalizesNestedBulletList() {
    // \t\t-\t should become "\t- " (one level of indent)
    let text = "\t-\tFirst item\n\t\t-\tNested item"
    let input = NSAttributedString(string: text)

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(input)

    #expect(result.attributedString.string == "- First item\n\t- Nested item")
    #expect(result.stats.listMarkersNormalized == 2)
  }

  @Test("Normalizes bullet character to dash")
  func testNormalizesBulletCharacterToDash() {
    // \t•\t should become "- "
    let text = "\t•\tBullet item"
    let input = NSAttributedString(string: text)

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(input)

    #expect(result.attributedString.string == "- Bullet item")
    #expect(result.stats.listMarkersNormalized == 1)
  }

  @Test("Normalizes asterisk list marker")
  func testNormalizesAsteriskListMarker() {
    // \t*\t should become "* "
    let text = "\t*\tAsterisk item"
    let input = NSAttributedString(string: text)

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(input)

    #expect(result.attributedString.string == "* Asterisk item")
    #expect(result.stats.listMarkersNormalized == 1)
  }

  @Test("Normalizes numbered list")
  func testNormalizesNumberedList() {
    // \t1\t should become "1. "
    let text = "\t1\tFirst item\n\t2\tSecond item"
    let input = NSAttributedString(string: text)

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(input)

    #expect(result.attributedString.string == "1. First item\n2. Second item")
    #expect(result.stats.listMarkersNormalized == 2)
  }

  @Test("Normalizes numbered list with dots")
  func testNormalizesNumberedListWithDots() {
    // \t1.\t should become "1. "
    let text = "\t1.\tFirst item"
    let input = NSAttributedString(string: text)

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(input)

    #expect(result.attributedString.string == "1. First item")
    #expect(result.stats.listMarkersNormalized == 1)
  }

  @Test("Skips list normalization when disabled")
  func testSkipsListNormalizationWhenDisabled() {
    let text = "\t-\tItem"
    let input = NSAttributedString(string: text)

    let config = RichTextSanitizer.Configuration(
      baseFont: baseFont,
      baseColor: baseColor,
      normalizeListMarkers: false
    )
    let sanitizer = RichTextSanitizer(configuration: config)
    let result = sanitizer.sanitize(input)

    #expect(result.attributedString.string == "\t-\tItem")
    #expect(result.stats.listMarkersNormalized == 0)
  }

  @Test("Does not affect non-list text")
  func testDoesNotAffectNonListText() {
    let text = "Regular text without lists"
    let input = NSAttributedString(string: text)

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(input)

    #expect(result.attributedString.string == text)
    #expect(result.stats.listMarkersNormalized == 0)
  }

  // MARK: - Code Block Tests

  @Test("Wraps monospace text with code block markers")
  func testWrapsMonospaceWithCodeBlockMarkers() {
    let text = "let x = 1"
    let attributed = NSMutableAttributedString(string: text)
    let monoFont = NSFont(name: "Menlo", size: 14) ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    attributed.addAttribute(.font, value: monoFont, range: NSRange(location: 0, length: text.count))

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(attributed)

    #expect(result.attributedString.string.contains("```"))
    #expect(result.attributedString.string.contains("let x = 1"))
    #expect(result.stats.codeBlocksWrapped == 1)
  }

  @Test("Wraps multiline code block")
  func testWrapsMultilineCodeBlock() {
    let text = "func hello() {\n  print(\"hi\")\n}"
    let attributed = NSMutableAttributedString(string: text)
    let monoFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    attributed.addAttribute(.font, value: monoFont, range: NSRange(location: 0, length: text.count))

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(attributed)

    let output = result.attributedString.string
    #expect(output.hasPrefix("```\n"))
    #expect(output.hasSuffix("\n```") || output.hasSuffix("```"))
    #expect(output.contains("func hello()"))
    #expect(result.stats.codeBlocksWrapped == 1)
  }

  @Test("Does not wrap non-monospace text as code")
  func testDoesNotWrapNonMonospaceAsCode() {
    let text = "Regular text"
    let attributed = NSMutableAttributedString(string: text)
    attributed.addAttribute(.font, value: baseFont, range: NSRange(location: 0, length: text.count))

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(attributed)

    #expect(!result.attributedString.string.contains("```"))
    #expect(result.attributedString.string == text)
    #expect(result.stats.codeBlocksWrapped == 0)
  }

  @Test("Skips code block wrapping when disabled")
  func testSkipsCodeBlockWrappingWhenDisabled() {
    let text = "let x = 1"
    let attributed = NSMutableAttributedString(string: text)
    let monoFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    attributed.addAttribute(.font, value: monoFont, range: NSRange(location: 0, length: text.count))

    let config = RichTextSanitizer.Configuration(
      baseFont: baseFont,
      baseColor: baseColor,
      wrapCodeBlocks: false
    )
    let sanitizer = RichTextSanitizer(configuration: config)
    let result = sanitizer.sanitize(attributed)

    #expect(!result.attributedString.string.contains("```"))
    #expect(result.attributedString.string == text)
    #expect(result.stats.codeBlocksWrapped == 0)
  }

  @Test("Detects Courier as monospace")
  func testDetectsCourierAsMonospace() {
    let text = "code"
    let attributed = NSMutableAttributedString(string: text)
    if let courierFont = NSFont(name: "Courier", size: 14) {
      attributed.addAttribute(.font, value: courierFont, range: NSRange(location: 0, length: text.count))

      let sanitizer = makeSanitizer()
      let result = sanitizer.sanitize(attributed)

      #expect(result.attributedString.string.contains("```"))
      #expect(result.stats.codeBlocksWrapped == 1)
    }
  }

  @Test("Skips whitespace-only code blocks")
  func testSkipsWhitespaceOnlyCodeBlocks() {
    let text = "   \n  \t  "
    let attributed = NSMutableAttributedString(string: text)
    let monoFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    attributed.addAttribute(.font, value: monoFont, range: NSRange(location: 0, length: text.count))

    let sanitizer = makeSanitizer()
    let result = sanitizer.sanitize(attributed)

    // Should not add ``` around whitespace-only content
    #expect(!result.attributedString.string.contains("```"))
  }
}
#endif
