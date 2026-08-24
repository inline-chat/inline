import AppKit
import Foundation
import MacTheme
import Testing

@Suite("Chat typography")
struct ChatTypographyTests {
  @Test("empty settings preserve the existing system message font exactly")
  func emptySettingsPreserveSystemFont() {
    let typography = ChatTypography.resolve(source: .init())
    let expected = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    #expect(typography.font.fontName == expected.fontName)
    #expect(typography.font.familyName == expected.familyName)
    #expect(typography.font.pointSize == expected.pointSize)
    #expect(typography.font.ascender == expected.ascender)
    #expect(typography.font.descender == expected.descender)
    #expect(typography.font.leading == expected.leading)
    #expect(typography.singleEmojiPointSize == 64)
    #expect(typography.threeEmojisPointSize == 42)
    #expect(typography.manyEmojisPointSize == 18)

    for pointSize: CGFloat in [NSFont.systemFontSize, 64, 42, 18] {
      let resized = typography.font(sized: pointSize)
      let expectedResized = NSFont.systemFont(ofSize: pointSize)
      #expect(resized.fontName == expectedResized.fontName)
      #expect(resized.pointSize == expectedResized.pointSize)
      #expect(resized.ascender == expectedResized.ascender)
      #expect(resized.descender == expectedResized.descender)
      #expect(resized.leading == expectedResized.leading)
    }

    for weight: NSFont.Weight in [.medium, .semibold] {
      let weighted = typography.font(sized: 17, weight: weight)
      let expectedWeighted = NSFont.systemFont(ofSize: 17, weight: weight)
      #expect(weighted.fontName == expectedWeighted.fontName)
      #expect(weighted.ascender == expectedWeighted.ascender)
      #expect(weighted.descender == expectedWeighted.descender)
      #expect(weighted.leading == expectedWeighted.leading)
    }
  }

  @Test("size override uses the system family and scales semantic message sizes")
  func customSizeUsesSystemFamily() {
    let typography = ChatTypography.resolve(
      source: .init(fontSize: "17.5")
    )
    let expected = NSFont.systemFont(ofSize: 17.5)

    #expect(typography.font.fontName == expected.fontName)
    #expect(typography.pointSize == 17.5)
    #expect(
      typography.singleEmojiPointSize
        == 17.5 * 64 / ChatTypography.systemPointSize
    )
  }

  @Test("invalid sizes fall back to the live system size")
  func invalidSizesUseSystemSize() {
    for value in ["not a number", "0", "-4", "inf", "nan"] {
      let typography = ChatTypography.resolve(
        source: .init(fontSize: value)
      )
      #expect(typography.pointSize == ChatTypography.systemPointSize)
    }
  }

  @Test("font families resolve in order and retain installed fallbacks")
  func orderedFontFamilies() throws {
    let families = NSFontManager.shared.availableFontFamilies
    let primary = try #require(
      families.first { $0.caseInsensitiveCompare("Menlo") == .orderedSame }
    )
    let fallback = try #require(
      families.first { $0.caseInsensitiveCompare("Helvetica Neue") == .orderedSame }
    )
    let typography = ChatTypography.resolve(
      source: .init(fontFamilies: "Missing Inline Font, \(primary), \(fallback)")
    )

    #expect(typography.font.familyName == primary)
    let cascade = typography.font.fontDescriptor.object(
      forKey: .cascadeList
    ) as? [NSFontDescriptor]
    #expect(cascade?.first?.object(forKey: .family) as? String == fallback)
  }

  @Test("all missing families fall back to System without rewriting the source")
  func missingFamiliesUseSystem() {
    let source = ChatTypography.Source(
      fontFamilies: "Missing Inline Font, Also Missing",
      fontSize: ""
    )
    let typography = ChatTypography.resolve(source: source)
    let expected = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    #expect(typography.font.fontName == expected.fontName)
    #expect(typography.source == source)
  }

  @Test("resizing preserves the selected family and fallback cascade")
  func resizingPreservesFamilyAndFallbacks() throws {
    let families = NSFontManager.shared.availableFontFamilies
    let primary = try #require(
      families.first { $0.caseInsensitiveCompare("Menlo") == .orderedSame }
    )
    let fallback = try #require(
      families.first { $0.caseInsensitiveCompare("Helvetica Neue") == .orderedSame }
    )
    let typography = ChatTypography.resolve(
      source: .init(fontFamilies: "\(primary), \(fallback)")
    )
    let resized = typography.font(sized: 19)
    let weighted = typography.font(sized: 19, weight: .semibold)

    #expect(resized.familyName == primary)
    #expect(resized.pointSize == 19)
    #expect(weighted.familyName == primary)
    #expect(weighted.pointSize == 19)
    let cascade = resized.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor]
    #expect(cascade?.first?.object(forKey: .family) as? String == fallback)
  }

  @Test("stored source keeps empty defaults and exact power-user input")
  func storedSource() throws {
    let suiteName = "ChatTypographyTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(ChatTypography.storedSource(userDefaults: defaults) == .init())

    defaults.set("Menlo, System", forKey: ChatTypography.fontFamiliesDefaultsKey)
    defaults.set("15.5", forKey: ChatTypography.fontSizeDefaultsKey)
    #expect(
      ChatTypography.storedSource(userDefaults: defaults)
        == .init(fontFamilies: "Menlo, System", fontSize: "15.5")
    )
  }
}
