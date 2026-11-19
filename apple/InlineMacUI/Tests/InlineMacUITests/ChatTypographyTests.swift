import AppKit
import CoreText
import Foundation
import MacTheme
import Testing

@Suite("Chat typography", .serialized)
struct ChatTypographyTests {
  @Test("empty settings use the system font at the default chat size")
  func emptySettingsPreserveSystemFont() {
    let typography = ChatTypography.resolve(source: .init())
    let expected = NSFont.systemFont(ofSize: ChatTypography.defaultPointSize)

    #expect(typography.font.fontName == expected.fontName)
    #expect(typography.font.familyName == expected.familyName)
    #expect(typography.font.pointSize == expected.pointSize)
    #expect(typography.font.ascender == expected.ascender)
    #expect(typography.font.descender == expected.descender)
    #expect(typography.font.leading == expected.leading)
    #expect(typography.singleEmojiPointSize == 64)
    #expect(typography.threeEmojisPointSize == 42)
    #expect(typography.manyEmojisPointSize == 18)

    for pointSize: CGFloat in [ChatTypography.defaultPointSize, 64, 42, 18] {
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
        == 17.5 * 64 / ChatTypography.defaultPointSize
    )
  }

  @Test("invalid sizes fall back to the default size")
  func invalidSizesUseSystemSize() {
    for value in ["not a number", "0", "-4", "inf", "nan"] {
      let typography = ChatTypography.resolve(
        source: .init(fontSize: value)
      )
      #expect(typography.pointSize == ChatTypography.defaultPointSize)
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
    let expected = NSFont.systemFont(ofSize: ChatTypography.defaultPointSize)

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

  @Test("line height parses, clamps and defaults to 1.28 em")
  func lineHeightParsing() {
    #expect(ChatTypography.resolve(source: .init()).lineHeight == ChatTypography.defaultLineHeight)
    #expect(ChatTypography.resolve(source: .init()).isDefaultLineHeight)
    for value in ["", "abc", "0", "-2", "nan"] {
      #expect(ChatTypography.resolve(source: .init(lineHeight: value)).lineHeight == ChatTypography.defaultLineHeight)
    }
    #expect(ChatTypography.resolve(source: .init(lineHeight: "0.5")).lineHeight == ChatTypography.minimumLineHeight)
    #expect(ChatTypography.resolve(source: .init(lineHeight: "1.4")).lineHeight == 1.4)
    #expect(ChatTypography.resolve(source: .init(lineHeight: "9")).lineHeight == ChatTypography.maximumLineHeight)
  }

  @Test("line spacing is whole points: line height × size, never below the natural line")
  func lineSpacingValues() {
    for size: CGFloat in [13, 14, 16, 22] {
      let font = NSFont.systemFont(ofSize: size)
      let natural = ChatTypography.naturalLineHeight(of: font)
      for lineHeight in ChatTypography.lineHeightSteps {
        let spacing = ChatTypography.lineSpacing(for: font, lineHeight: lineHeight)
        #expect(spacing == spacing.rounded())
        #expect(spacing == max(0, (lineHeight * size).rounded() - natural))
      }
      // Compact is the natural line at every size the ladder offers around body text.
      #expect(ChatTypography.lineSpacing(for: font, lineHeight: 1.2) == 0)
    }
    // The default adds a point at the default size.
    #expect(ChatTypography.resolve(source: .init()).lineSpacing == 1)
    let typography = ChatTypography.resolve(source: .init(fontSize: "26", lineHeight: "1.5"))
    #expect(typography.lineSpacing(forPointSize: 26) > typography.lineSpacing(forPointSize: 13))
  }

  @Test("spacing scale rounds em values to whole points and scales with size")
  func spacingScale() {
    #expect(ChatTypography.space(.paragraph, at: 14) == 12)
    #expect(ChatTypography.space(.listItem, at: 14) == 5)
    #expect(ChatTypography.space(.block, at: 14) == 7)
    #expect(ChatTypography.space(.headingAbove, at: 14) == 16)
    #expect(ChatTypography.space(.headingBelow, at: 14) == 9)
    #expect(ChatTypography.space(.codePadding, at: 14) == 11)
    #expect(ChatTypography.space(.quoteLeadingInset, at: 14) == ChatTypography.space(.codePadding, at: 14))
    for space: ChatTypography.Space in [.paragraph, .listItem, .block, .headingAbove, .codePadding] {
      #expect(ChatTypography.space(space, at: 20) >= ChatTypography.space(space, at: 14))
      #expect(ChatTypography.space(space, at: 14) == ChatTypography.space(space, at: 14).rounded())
    }
    #expect(ChatTypography.headingPointSize(level: 1, at: 14) == 17.5)
    #expect(ChatTypography.headingPointSize(level: 2, at: 14) == 16)
    #expect(ChatTypography.headingPointSize(level: 3, at: 14) == 15)
    #expect(ChatTypography.headingPointSize(level: 4, at: 14) == 14)
    #expect(ChatTypography.codeBlockPointSize(at: 14) == 12.5)
    #expect(ChatTypography.inlineCodePointSize(at: 14) == 13.5)
    #expect(ChatTypography.bulletDiameter(at: 14) == 4)
    // Text gaps add back the line spacing a separate text block drops.
    let typography = ChatTypography.resolve(source: .init())
    #expect(typography.textGap(.paragraph, at: 14) == 12 + typography.lineSpacing(forPointSize: 14))
  }

  @Test("system designs resolve to their design and keep it when resized", arguments: [
    ChatTypography.SystemDesign.serif, .rounded, .monospaced,
  ])
  func systemDesigns(design: ChatTypography.SystemDesign) {
    let typography = ChatTypography.resolve(source: .init(fontFamilies: design.token, fontSize: "15"))
    let system = NSFont.systemFont(ofSize: 15)

    #expect(typography.selectedSystemDesign == design)
    #expect(typography.pointSize == 15)
    #expect(typography.font.fontName != system.fontName)
    #expect(typography.font(sized: 20).fontName != NSFont.systemFont(ofSize: 20).fontName)
    #expect(typography.font(sized: 20, weight: .semibold).pointSize == 20)
  }

  @Test("the system token and an empty family list are the same plain system font")
  func systemToken() {
    let token = ChatTypography.resolve(source: .init(fontFamilies: "System"))
    let empty = ChatTypography.resolve(source: .init())
    #expect(token.selectedSystemDesign == .standard)
    #expect(token.font.fontName == empty.font.fontName)
  }

  @Test("size steps move to the next step, snap fractional sizes and stop at the ends")
  func sizeSteps() {
    #expect(ChatTypography.nextLargerSize(than: 13) == 14)
    #expect(ChatTypography.nextSmallerSize(than: 13) == 12)
    #expect(ChatTypography.nextLargerSize(than: 18) == 20)
    #expect(ChatTypography.nextLargerSize(than: 15.5) == 16)
    #expect(ChatTypography.nextSmallerSize(than: 15.5) == 15)
    #expect(ChatTypography.nextLargerSize(than: ChatTypography.maximumPointSize) == nil)
    #expect(ChatTypography.nextSmallerSize(than: ChatTypography.minimumPointSize) == nil)
    #expect(ChatTypography.sizeSteps.contains(ChatTypography.defaultPointSize))
  }

  @Test("applying a change bumps the revision and notifies; an equivalent source does not")
  @MainActor
  func liveApply() {
    let original = ChatTypography.current.source
    defer { ChatTypography.apply(original) }

    ChatTypography.apply(.init())
    let before = ChatTypography.current.revision

    final class Counter: @unchecked Sendable { var value = 0 }
    let notifications = Counter()
    let observer = NotificationCenter.default.addObserver(
      forName: ChatTypography.didChangeNotification, object: nil, queue: nil
    ) { _ in notifications.value += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }

    #expect(ChatTypography.apply(.init(fontSize: "17")))
    #expect(ChatTypography.current.pointSize == 17)
    #expect(ChatTypography.current.revision != before)

    let changed = ChatTypography.current.revision
    #expect(!ChatTypography.apply(.init(fontSize: "17.0")))
    #expect(ChatTypography.current.revision == changed)
    #expect(ChatTypography.current.source.fontSize == "17.0")

    #expect(ChatTypography.apply(.init(fontSize: "17", lineHeight: "1.3")))
    #expect(notifications.value == 2)
  }

  @Test("line spacing keeps existing paragraph attributes and skips excluded ranges")
  func applyLineSpacingToText() {
    let text = NSMutableAttributedString(string: "one\ncode\nthree")
    let indented = NSMutableParagraphStyle()
    indented.headIndent = 8
    text.addAttribute(.paragraphStyle, value: indented, range: NSRange(location: 4, length: 5))

    ChatTypography.applyLineSpacing(4, to: text) { $0.location == 4 }

    let first = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    let code = text.attribute(.paragraphStyle, at: 5, effectiveRange: nil) as? NSParagraphStyle
    let last = text.attribute(.paragraphStyle, at: 10, effectiveRange: nil) as? NSParagraphStyle
    #expect(first?.lineSpacing == 4)
    #expect(code?.lineSpacing == 0)
    #expect(code?.headIndent == 8)
    #expect(last?.lineSpacing == 4)
  }

  @Test("Core Text measures line-spaced text at least as tall as TextKit 2 draws it", arguments: [
    "Readable text with enough words to wrap into several lines at this width so engines can be compared.\nSecond paragraph.",
    "\u{0633}\u{0644}\u{0627}\u{0645} \u{062F}\u{0646}\u{06CC}\u{0627} mixed with English words that wrap onto more lines here.",
    "Emoji \u{1F600}\u{1F389} and \u{0E17}\u{0E14}\u{0E2A}\u{0E2D}\u{0E1A} Thai with marks in a wrapping message text.",
  ])
  @MainActor
  func measurementParity(text: String) {
    let width: CGFloat = 220
    for lineHeight in ChatTypography.lineHeightSteps {
      let typography = ChatTypography.resolve(source: .init(lineHeight: ChatTypography.format(lineHeight)))
      let value = NSMutableAttributedString(string: text, attributes: [.font: typography.font])
      ChatTypography.applyLineSpacing(typography.lineSpacing, to: value)

      let framesetter = CTFramesetterCreateWithAttributedString(value)
      let measured = ceil(CTFramesetterSuggestFrameSizeWithConstraints(
        framesetter, CFRange(location: 0, length: value.length), nil,
        CGSize(width: width, height: .greatestFiniteMagnitude), nil
      ).height)

      let textView = NSTextView(usingTextLayoutManager: true)
      textView.textContainer?.lineFragmentPadding = 0
      textView.textContainerInset = .zero
      textView.textContainer?.size = CGSize(width: width, height: .greatestFiniteMagnitude)
      textView.textStorage?.setAttributedString(value)
      var drawn: CGFloat = 0
      if let layoutManager = textView.textLayoutManager {
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        layoutManager.enumerateTextLayoutFragments(
          from: layoutManager.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
          drawn = max(drawn, fragment.layoutFragmentFrame.maxY)
          return true
        }
      }
      drawn = ceil(drawn)

      #expect(measured >= drawn, "line height \(lineHeight)")
      #expect(measured - drawn <= 6, "line height \(lineHeight)")
    }
  }

  @Test("a fallback keeps the main font's system design at every size and weight")
  func fallbackKeepsSystemDesign() throws {
    let families = NSFontManager.shared.availableFontFamilies
    let fallback = try #require(
      families.first { $0.caseInsensitiveCompare("Geeza Pro") == .orderedSame }
        ?? families.first { $0.caseInsensitiveCompare("Helvetica Neue") == .orderedSame }
    )
    let typography = ChatTypography.resolve(
      source: .init(fontFamilies: "\(ChatTypography.SystemDesign.serif.token), \(fallback)")
    )
    let serif = ChatTypography.resolve(source: .init(fontFamilies: ChatTypography.SystemDesign.serif.token))

    #expect(typography.selectedSystemDesign == .serif)
    for font in [typography.font, typography.font(sized: 20), typography.font(sized: 20, weight: .semibold)] {
      #expect(font.familyName == serif.font.familyName)
      let cascade = font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor]
      #expect(cascade?.first?.object(forKey: .family) as? String == fallback)
    }
  }

  @Test("a plain system main font takes a fallback without changing its metrics")
  func systemWithFallback() throws {
    let families = NSFontManager.shared.availableFontFamilies
    let fallback = try #require(families.first { $0.caseInsensitiveCompare("Menlo") == .orderedSame })
    let typography = ChatTypography.resolve(source: .init(fontFamilies: "System, \(fallback)"))
    let system = NSFont.systemFont(ofSize: ChatTypography.defaultPointSize)

    #expect(typography.selectedSystemDesign == .standard)
    #expect(typography.font.familyName == system.familyName)
    #expect(typography.font.ascender == system.ascender)
    #expect(typography.font.descender == system.descender)
  }

  @Test("the code font uses an installed family and falls back to SF Mono")
  func codeFont() throws {
    let defaultCode = ChatTypography.resolve(source: .init()).codeFont(sized: 12)
    #expect(defaultCode.fontName == NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName)

    let menlo = try #require(
      NSFontManager.shared.availableFontFamilies.first { $0.caseInsensitiveCompare("Menlo") == .orderedSame }
    )
    let typography = ChatTypography.resolve(source: .init(codeFontFamily: menlo.lowercased()))
    #expect(typography.codeFontFamilyName == menlo)
    #expect(typography.codeFont(sized: 12).familyName == menlo)
    #expect(typography.codeFont(sized: 12, weight: .semibold).pointSize == 12)

    let missing = ChatTypography.resolve(source: .init(codeFontFamily: "Missing Inline Mono"))
    #expect(missing.codeFontFamilyName == nil)
    #expect(ChatTypography.installedMonospacedFamilies().contains(menlo))
  }

  @Test("changing only the code font is a live change")
  @MainActor
  func codeFontApplies() throws {
    let original = ChatTypography.current.source
    defer { ChatTypography.apply(original) }
    ChatTypography.apply(.init())
    #expect(ChatTypography.apply(.init(codeFontFamily: "Menlo")))
    #expect(!ChatTypography.apply(.init(codeFontFamily: "menlo")))
  }

  @Test("family lists split, trim and join in order")
  func familyLists() {
    #expect(ChatTypography.familyList(" New York ,, Menlo,") == ["New York", "Menlo"])
    #expect(ChatTypography.familyString(["system", "Geeza Pro"]) == "system, Geeza Pro")
  }
}
