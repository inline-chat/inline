import CoreGraphics
import Foundation
import Testing
@testable import InlineMessageLayout

@Suite("Text layout")
struct TextLayoutTests {
  let grid = Fixtures.grid

  @Test("A short string is one pixel-aligned line")
  func singleLine() {
    let layout = TextLayouter.layout(Fixtures.text("Hello there"), maximumWidth: 300, grid: grid)
    #expect(layout.lineCount == 1)
    #expect(layout.size.width > 0 && layout.size.width < 300)
    #expect(layout.size.height >= 20 && layout.size.height <= 23)
    #expect(grid.isAligned(layout.size.width) && grid.isAligned(layout.size.height))
    #expect(grid.isAligned(layout.firstBaseline))
  }

  @Test("Long text wraps within the width and never overflows")
  func wraps() {
    let string = String(repeating: "Layout should wrap at word boundaries. ", count: 6)
    for width: CGFloat in [120, 200, 280] {
      let layout = TextLayouter.layout(Fixtures.text(string), maximumWidth: width, grid: grid)
      #expect(layout.lineCount > 1)
      #expect(layout.lines.allSatisfy { $0.width <= width + 0.5 })
      #expect(layout.size.width <= grid.ceil(width))
      // Lines tile the string with no gaps or overlaps.
      #expect(layout.lines.first?.range.location == 0)
      #expect(NSMaxRange(layout.lines.last!.range) == (string as NSString).length)
      for pair in zip(layout.lines, layout.lines.dropFirst()) {
        #expect(NSMaxRange(pair.0.range) == pair.1.range.location)
        #expect(pair.1.frame.minY >= pair.0.frame.maxY - 0.001)
      }
    }
  }

  @Test("Hard breaks make lines and paragraph spacing; a trailing newline adds none")
  func hardBreaks() {
    let style = TextLayoutStyle(paragraphSpacing: 4)
    let layout = TextLayouter.layout(Fixtures.text("One\n\nThree"), style: style, maximumWidth: 300, grid: grid)
    #expect(layout.lineCount == 3)
    #expect(layout.lines.allSatisfy { $0.endsParagraph })
    #expect(abs(layout.lines[1].frame.minY - layout.lines[0].frame.maxY - 4) < 0.5)

    let trailing = TextLayouter.layout(Fixtures.text("One\n"), maximumWidth: 300, grid: grid)
    let plain = TextLayouter.layout(Fixtures.text("One"), maximumWidth: 300, grid: grid)
    #expect(trailing.lineCount == 1)
    #expect(trailing.size.height == plain.size.height)
  }

  @Test("Paragraph direction follows the first strong letter")
  func direction() {
    let persian = TextLayouter.layout(Fixtures.text("سلام دنیا"), maximumWidth: 300, grid: grid)
    #expect(persian.lines.first?.direction == .rightToLeft)
    let numberFirst = TextLayouter.layout(Fixtures.text("123 שלום"), maximumWidth: 300, grid: grid)
    #expect(numberFirst.lines.first?.direction == .rightToLeft)
    let english = TextLayouter.layout(Fixtures.text("Hello سلام"), maximumWidth: 300, grid: grid)
    #expect(english.lines.first?.direction == .leftToRight)
    let symbols = TextLayouter.layout(
      Fixtures.text("😀 123"),
      style: TextLayoutStyle(fallbackDirection: .rightToLeft),
      maximumWidth: 300,
      grid: grid
    )
    #expect(symbols.lines.first?.direction == .rightToLeft)

    let mixed = TextLayouter.layout(Fixtures.text("Hello\nسلام"), maximumWidth: 300, grid: grid)
    #expect(mixed.lines.map(\.direction) == [.leftToRight, .rightToLeft])
  }

  @Test("Aligning moves right-to-left lines to the trailing edge")
  func alignment() {
    let layout = TextLayouter.layout(Fixtures.text("Hi\nسلام"), maximumWidth: 300, grid: grid)
      .aligned(toWidth: 200)
    #expect(layout.size.width == 200)
    #expect(layout.lines[0].frame.minX == 0)
    #expect(abs(layout.lines[1].frame.maxX - 200) < 0.01)
  }

  @Test("Hit testing finds the character under a point and the rects of a range")
  func hitTesting() throws {
    let string = "Open the link now"
    let layout = TextLayouter.layout(Fixtures.text(string), maximumWidth: 300, grid: grid)
    let line = try #require(layout.lines.first)
    #expect(layout.characterIndex(at: CGPoint(x: 1, y: line.frame.midY)) == 0)
    #expect(layout.characterIndex(at: CGPoint(x: line.frame.maxX + 20, y: line.frame.midY)) == nil)
    #expect(layout.characterIndex(at: CGPoint(x: 1, y: line.frame.maxY + 5)) == nil)

    let link = (string as NSString).range(of: "link")
    let rects = layout.rects(for: link)
    #expect(rects.count == 1)
    let rect = try #require(rects.first)
    #expect(rect.minX > 0 && rect.maxX < line.frame.maxX)
    #expect(layout.characterIndex(at: CGPoint(x: rect.midX, y: rect.midY)).map { NSLocationInRange($0, link) } == true)
  }

  @Test("Reveal height grows one line at a time")
  func revealHeight() {
    let string = String(repeating: "Streaming text arrives in pieces. ", count: 5)
    let layout = TextLayouter.layout(Fixtures.text(string), maximumWidth: 160, grid: grid)
    #expect(layout.height(revealingCharacters: 0) == layout.lines[0].frame.maxY)
    let secondLineStart = layout.lines[1].range.location
    #expect(layout.height(revealingCharacters: secondLineStart) == layout.lines[1].frame.maxY)
    #expect(layout.height(revealingCharacters: layout.length) == layout.size.height)
  }

  @Test("Ink bounds cover marks that reach past the line box")
  func inkBounds() {
    let plain = TextLayouter.layout(Fixtures.text("Hello"), maximumWidth: 300, grid: grid)
    #expect(!plain.inkBounds.isNull)
    #expect(plain.inkBounds.minY >= 0 && plain.inkBounds.maxY <= plain.size.height)

    let stacked = TextLayouter.layout(
      Fixtures.text("Z\u{0351}\u{0352}\u{0351}\u{0352}a\u{0300}\u{0300}\u{0300}"),
      maximumWidth: 300,
      grid: grid
    )
    #expect(stacked.inkBounds.minY < 0, "stacked marks should rise above the line: \(stacked.inkBounds)")
  }

  @Test("Widths narrower than one character still finish")
  func tinyWidth() {
    let layout = TextLayouter.layout(Fixtures.text("Wide"), maximumWidth: 1, grid: grid)
    #expect(layout.lineCount == 4)
    #expect(TextLayouter.layout(Fixtures.text(""), maximumWidth: 100, grid: grid).lineCount == 0)
  }

  @Test("The cache returns the same layout and stays within its budget")
  func cache() {
    let cache = TextLayoutCache(characterBudget: 100)
    let text = Fixtures.text("Cached text")
    let first = cache.layout(text, maximumWidth: 200, grid: grid)
    let second = cache.layout(Fixtures.text("Cached text"), maximumWidth: 200, grid: grid)
    #expect(first.lines.first?.ctLine === second.lines.first?.ctLine)
    #expect(cache.count == 1)
    _ = cache.layout(text, maximumWidth: 120, grid: grid)
    #expect(cache.count == 2)
    for index in 0 ..< 20 {
      _ = cache.layout(Fixtures.text("Entry \(index)"), maximumWidth: 200, grid: grid)
    }
    #expect(cache.count <= 100 / 7 + 1)
    // Over a quarter of the budget is laid out but not kept.
    _ = cache.layout(Fixtures.text(String(repeating: "x", count: 30)), maximumWidth: 200, grid: grid)
    #expect(cache.count <= 100 / 7 + 1)
  }
}
