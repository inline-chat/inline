import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import InlineMessageLayout

/// Long paragraphs break through windows (`LongParagraphBreaker`); the lines must be exactly the
/// ones Core Text gives breaking the whole paragraph at once.
@Suite("Long paragraphs")
struct LongParagraphTests {
  let grid = PixelGrid(scale: 2)

  func text(_ string: String) -> MessageText {
    Fixtures.text(string, font: Fixtures.font(13))
  }

  func repeated(_ unit: String, to length: Int) -> String {
    var result = ""
    while (result as NSString).length < length { result += unit }
    return String((result as NSString).substring(to: length))
  }

  /// Line starts from one typesetter over the whole text, without Core Text's work limit. The
  /// default typesetter breaks long right-to-left paragraphs short (a first Persian line at
  /// 342 of 420 points); the unbounded one, the windows and TextKit don't.
  func referenceStarts(_ text: MessageText, width: CGFloat) -> [Int] {
    let options = [kCTTypesetterOptionAllowUnboundedLayout: true] as CFDictionary
    let typesetter = CTTypesetterCreateWithAttributedStringAndOptions(text.attributedString, options)!
    var starts: [Int] = []
    var start = 0
    while start < text.length {
      starts.append(start)
      start += max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(width)))
    }
    return starts
  }

  @Test("Windowed breaks match whole-paragraph breaks", arguments: [
    "The quick brown fox jumps over the lazy dog, and the scroll hitch shows up in pasted logs. ",
    "{\"id\":42,\"name\":\"inline\",\"tags\":[\"chat\",\"agents\"],\"ok\":true},",
    "سلام این یک پیام طولانی است که Inline را روی مک امتحان می‌کند و اسکرول روان‌تر شده است. ",
  ])
  func matchesWholeParagraph(unit: String) {
    let message = text(repeated(unit, to: 12_000))
    let layout = TextLayouter.layout(message, maximumWidth: 420, grid: grid)
    #expect(layout.lines.map(\.range.location) == referenceStarts(message, width: 420))
    #expect(NSMaxRange(layout.lines.last!.range) == message.length)
  }

  @Test("A token longer than a window still breaks the same way")
  func longToken() {
    let token = repeated("QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo", to: 6_000)
    let message = text(repeated("Some words before it. ", to: 1_000) + token + repeated(" and after it", to: 1_000))
    let layout = TextLayouter.layout(message, maximumWidth: 300, grid: grid)
    #expect(layout.lines.map(\.range.location) == referenceStarts(message, width: 300))
  }

  @Test("Only the long paragraph changes path; short ones around it lay out as before")
  func mixedParagraphs() {
    let short = "A short paragraph before.\n"
    let message = text(short + repeated("Long paragraph text that keeps going. ", to: 9_000) + "\n" + short)
    let layout = TextLayouter.layout(message, maximumWidth: 380, grid: grid)
    #expect(layout.lines.map(\.range.location) == referenceStarts(message, width: 380))
  }

  @Test("Short paragraphs in a long right-to-left message break like the unbounded reference")
  func longMessageOfShortParagraphs() {
    let paragraph = "سلام این یک پیام است که Inline را روی مک امتحان می‌کند و اسکرول روان‌تر شده است و کمی پرش دارد.\n"
    let message = text(repeated(paragraph, to: 12_000))
    let layout = TextLayouter.layout(message, maximumWidth: 420, grid: grid)
    #expect(layout.lines.map(\.range.location) == referenceStarts(message, width: 420))
  }

  @Test("Arabic-script letters stay shaped past Core Text's work limit")
  func shapingInLongText() {
    let paragraph = "سلام این یک پیام است که Inline را روی مک امتحان می‌کند و اسکرول روان‌تر شده است و کمی پرش دارد.\n"
    let message = text(repeated(paragraph, to: 12_000))
    let layout = TextLayouter.layout(message, maximumWidth: 420, grid: grid)
    let string = message.attributedString.string as NSString
    // Each line shaped on its own: the glyphs and width it must have.
    for line in layout.lines.prefix(20) {
      let alone = CTLineCreateWithAttributedString(message.attributedString.attributedSubstring(from: line.range))
      #expect(CTLineGetGlyphCount(line.ctLine) == CTLineGetGlyphCount(alone), "\(string.substring(with: line.range))")
      #expect(abs(CTLineGetTypographicBounds(line.ctLine, nil, nil, nil) - CTLineGetTypographicBounds(alone, nil, nil, nil)) < 0.5)
    }
  }

  @Test("A 40-paragraph message of 12k characters stays fast")
  func longMessageOfParagraphs() {
    let message = text(repeated("Paragraph text that wraps over a few lines in a long message from an agent or a paste. It keeps going a bit.\n", to: 12_000))
    _ = TextLayouter.layout(message, maximumWidth: 420, grid: grid)
    let start = ContinuousClock.now
    let layout = TextLayouter.layout(message, maximumWidth: 420, grid: grid)
    let elapsed = ContinuousClock.now - start
    #expect(layout.lineCount > 100)
    #expect(elapsed < .milliseconds(60))
  }

  @Test("A 48k-character paragraph lays out in well under a second")
  func scales() {
    let message = text(repeated("The quick brown fox jumps over the lazy dog. ", to: 48_000))
    let start = ContinuousClock.now
    let layout = TextLayouter.layout(message, maximumWidth: 420, grid: grid)
    let elapsed = ContinuousClock.now - start
    #expect(layout.lineCount > 500)
    // Breaking the whole paragraph at once took about a second; windows take about 0.1 s.
    #expect(elapsed < .milliseconds(400))
  }
}
