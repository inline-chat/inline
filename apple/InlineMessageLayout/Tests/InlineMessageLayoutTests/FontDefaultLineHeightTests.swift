import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import InlineMessageLayout

/// `.fontDefault` reproduces TextKit's line boxes. The expected numbers were measured from
/// `NSTextView` (TextKit 2) on macOS 27 with the system font: 13 pt lines are 16 pt tall with
/// the baseline 13 pt below the top, `lineSpacing` follows every line, and
/// fallback fonts never make a line taller.
@Suite("Font-default line height", .serialized)
struct FontDefaultLineHeightTests {
  let grid = PixelGrid(scale: 2)
  let style = TextLayoutStyle(lineHeight: .fontDefault)

  func text(_ string: String, size: CGFloat = 13) -> MessageText {
    Fixtures.text(string, font: CTFontCreateUIFontForLanguage(.system, size, nil)!)
  }

  @Test("Lines sit on the system font's 16 pt pitch with the baseline where AppKit draws it")
  func pitch() {
    let layout = TextLayouter.layout(text("one\ntwo\nthree"), style: style, maximumWidth: 300, grid: grid)
    #expect(layout.lineCount == 3)
    #expect(layout.lines.map(\.frame.minY) == [0, 16, 32])
    #expect(layout.lines.allSatisfy { $0.frame.height == 16 })
    #expect(layout.size.height == 48)
    #expect(layout.lines.allSatisfy { $0.baseline - $0.frame.minY == 13 })
  }

  @Test("Line height follows the point size like AppKit's default line height")
  func sizes() {
    // AppKit: 12 pt → 15, 16 pt → 18, 20 pt → 23, 64 pt → 76.
    for (size, expected) in [(CGFloat(12), CGFloat(15)), (16, 18), (20, 23), (64, 76)] {
      let layout = TextLayouter.layout(text("Hg", size: size), style: style, maximumWidth: 300, grid: grid)
      #expect(layout.size.height == expected)
    }
  }

  @Test("Fallback fonts don't make a line taller; a larger attributed font does")
  func fallbackAndMixed() {
    for sample in ["नमस्ते! क्या आप", "สวัสดีครับ วันนี้", "hi 🎉 there"] {
      let layout = TextLayouter.layout(text(sample), style: style, maximumWidth: 600, grid: grid)
      #expect(layout.size.height == 16)
    }
    let mixed = NSMutableAttributedString(attributedString: text("small BIG small").attributedString)
    mixed.addAttribute(
      NSAttributedString.Key(kCTFontAttributeName as String),
      value: CTFontCreateUIFontForLanguage(.system, 20, nil)!,
      range: NSRange(location: 6, length: 3)
    )
    let layout = TextLayouter.layout(MessageText(mixed), style: style, maximumWidth: 600, grid: grid)
    #expect(layout.size.height == 23)
  }

  @Test("Line spacing follows every line and paragraph spacing ends paragraphs")
  func spacing() {
    let spaced = TextLayoutStyle(lineSpacing: 3, paragraphSpacing: 5, lineHeight: .fontDefault)
    let layout = TextLayouter.layout(text("aaa\nbbb\nccc"), style: spaced, maximumWidth: 300, grid: grid)
    #expect(layout.lines.map(\.frame.minY) == [0, 24, 48])
  }

  @Test("An installed provider supplies the metrics")
  func provider() {
    FontLineMetricsProvider.install { _ in FontLineMetrics(height: 20, baseline: 15) }
    defer { FontLineMetricsProvider.install { FontLineMetrics.coreTextDefault(for: $0) } }
    let layout = TextLayouter.layout(text("one\ntwo"), style: style, maximumWidth: 300, grid: grid)
    #expect(layout.lines.map(\.frame.minY) == [0, 20])
    #expect(layout.lines[1].baseline == 35)
  }

  @Test("A forced base direction applies to every paragraph")
  func forcedDirection() {
    let rtl = TextLayoutStyle(lineHeight: .fontDefault, baseDirection: .rightToLeft)
    let layout = TextLayouter.layout(text("Hello\nسلام"), style: rtl, maximumWidth: 300, grid: grid)
    #expect(layout.lines.allSatisfy { $0.direction == .rightToLeft })
    let aligned = layout.aligned(toWidth: 300)
    #expect(aligned.lines.allSatisfy { abs($0.frame.maxX - 300) < 0.5 })
    let natural = TextLayouter.layout(text("Hello\nسلام"), maximumWidth: 300, grid: grid)
    #expect(natural.lines.map(\.direction) == [.leftToRight, .rightToLeft])
  }
}

/// Paragraph metrics under `.fontDefault`, against TextKit 2 (macOS 27): a 13 pt text paragraph
/// with 2 pt line spacing, a 12 pt monospaced code block (6 pt before and after, 11 pt indent),
/// then text again. TextKit puts a line's spacing above it from its own paragraph.
extension FontDefaultLineHeightTests {
// Nested so it runs serialized with the provider tests above: both swap the global provider.
@Suite("Paragraph metrics")
struct ParagraphMetricsTests {
  let grid = PixelGrid(scale: 2)

  func text(_ parts: [(String, CGFloat, Bool, TextParagraphMetrics)]) -> MessageText {
    let result = NSMutableAttributedString()
    for (string, size, mono, metrics) in parts {
      let font = mono
        ? CTFontCreateWithName("Menlo" as CFString, size, nil)
        : CTFontCreateUIFontForLanguage(.system, size, nil)!
      result.append(NSAttributedString(string: string, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        TextParagraphMetrics.attributeKey: metrics,
      ]))
    }
    return MessageText(result)
  }

  @Test("Spacing between text and a code block follows TextKit")
  func codeBlock() {
    FontLineMetricsProvider.install { font in
      // The heights TextKit gave: 16 for 13 pt system, 15 for 12 pt monospaced.
      let height: CGFloat = CTFontGetSize(font) == 13 ? 16 : 15
      return FontLineMetrics(height: height, baseline: height - 3)
    }
    defer { FontLineMetricsProvider.install { FontLineMetrics.coreTextDefault(for: $0) } }
    let layout = TextLayouter.layout(
      text([
        ("Before\n", 13, false, TextParagraphMetrics(lineSpacing: 2)),
        ("code1\n", 12, true, TextParagraphMetrics(firstLineHeadIndent: 11, headIndent: 11, spacingBefore: 6)),
        ("code2\n", 12, true, TextParagraphMetrics(firstLineHeadIndent: 11, headIndent: 11, spacingAfter: 6)),
        ("After", 13, false, TextParagraphMetrics(lineSpacing: 2)),
      ]),
      style: TextLayoutStyle(lineHeight: .fontDefault),
      maximumWidth: 300,
      grid: grid
    )
    #expect(layout.lines.map(\.frame.minY) == [0, 22, 37, 60])
    #expect(layout.lines.map(\.leadingIndent) == [0, 11, 11, 0])
    #expect(layout.size.height == 76)
  }

  @Test("Indents narrow the lines and move them in")
  func indents() {
    let metrics = TextParagraphMetrics(firstLineHeadIndent: 20, headIndent: 10, tailIndent: -30)
    let words = String(repeating: "word ", count: 40)
    let layout = TextLayouter.layout(
      text([(words, 13, false, metrics)]),
      style: TextLayoutStyle(lineHeight: .fontDefault),
      maximumWidth: 200,
      grid: grid
    )
    #expect(layout.lines.first?.frame.minX == 20)
    #expect(layout.lines.dropFirst().allSatisfy { $0.frame.minX == 10 })
    #expect(layout.lines.allSatisfy { $0.frame.maxX <= 170.5 })
  }
}
}
