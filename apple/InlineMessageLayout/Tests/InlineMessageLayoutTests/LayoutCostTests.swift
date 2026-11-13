import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import InlineMessageLayout

@Suite("Layout cost")
struct LayoutCostTests {
  let grid = Fixtures.grid

  // MARK: - Widest word

  /// The measurement the planner used before: each word typeset on its own.
  func widestWordTypesetAlone(_ text: MessageText) -> CGFloat {
    let string = text.attributedString.string as NSString
    var widest: CGFloat = 0
    var location = 0
    while location < string.length {
      let space = string.rangeOfCharacter(
        from: .whitespacesAndNewlines,
        options: [],
        range: NSRange(location: location, length: string.length - location)
      )
      let end = space.location == NSNotFound ? string.length : space.location
      if end > location {
        let word = MessageText(text.attributedString.attributedSubstring(from: NSRange(location: location, length: end - location)))
        widest = max(widest, TextLayouter.layout(word, maximumWidth: .greatestFiniteMagnitude, grid: grid).size.width)
      }
      location = space.location == NSNotFound ? string.length : space.location + max(1, space.length)
    }
    return widest
  }

  static let cells = [
    "Revenue",
    "Quarterly revenue growth",
    "a b c",
    "supercalifragilisticexpialidocious and short",
    "درآمد سه‌ماهه",
    "رشد درآمد فصلی شرکت",
    "مرحبا بالعالم الجميل",
    "Claude Code نسخه‌ی جدید",
    "نسخه‌ی Claude جدید است",
    "foo(بار)baz 42٪",
    "עברית ו־English mixed",
    "👍🏽 🎉🎉🎉 👨‍👩‍👧‍👦",
    "emoji👍🏽inside words",
    "first line\nsecond longer line\nthird",
    "سطر اول\nسطر دوم طولانی‌تر\nthird line",
    "  leading and trailing  ",
    "tab\tseparated\tvalues",
    "",
    " ",
    "1,234,567.89",
  ]

  @Test("The widest word read from the cell layout matches typesetting each word", arguments: cells)
  func widestWordMatchesPerWord(_ string: String) {
    for font in [Fixtures.body, Fixtures.caption, Fixtures.font(15)] {
      let text = Fixtures.text(string, font: font)
      let cell = TextLayouter.layout(text, maximumWidth: .greatestFiniteMagnitude, grid: grid)
      let derived = grid.ceil(cell.widestUnbreakableRunWidth())
      let alone = widestWordTypesetAlone(text)
      let pixel = 1 / grid.scale
      #expect(derived >= alone - pixel - 0.001, "\(string): \(derived) narrower than \(alone)")
      #expect(abs(derived - alone) <= pixel + 0.001, "\(string): \(derived) vs \(alone)")
    }
  }

  @Test("Mixed fonts in one cell still measure per word")
  func widestWordMixedFonts() {
    let attributed = NSMutableAttributedString(
      string: "small ",
      attributes: [NSAttributedString.Key(kCTFontAttributeName as String): Fixtures.caption]
    )
    attributed.append(NSAttributedString(
      string: "BIG",
      attributes: [NSAttributedString.Key(kCTFontAttributeName as String): Fixtures.font(30)]
    ))
    attributed.append(NSAttributedString(
      string: "ger tail",
      attributes: [NSAttributedString.Key(kCTFontAttributeName as String): Fixtures.caption]
    ))
    let text = MessageText(attributed)
    let cell = TextLayouter.layout(text, maximumWidth: .greatestFiniteMagnitude, grid: grid)
    let derived = grid.ceil(cell.widestUnbreakableRunWidth())
    let alone = widestWordTypesetAlone(text)
    #expect(abs(derived - alone) <= 1 / grid.scale + 0.001, "\(derived) vs \(alone)")
  }

  @Test("A table column never gets narrower than its widest word")
  func tableColumnFitsWidestWord() throws {
    let cells = ["Name", "supercalifragilisticexpialidocious", "رشد درآمد فصلی", "ok"]
    let table = RichTable(
      rows: [[Fixtures.text(cells[0]), Fixtures.text(cells[1])], [Fixtures.text(cells[2]), Fixtures.text(cells[3])]],
      alignments: [],
      isRightToLeft: false
    )
    let layout = try #require(RichLayoutPlanner.layout([.table(table)], maximumWidth: 120, grid: grid))
    guard case let .table(node) = layout.nodes.first?.node else {
      Issue.record("expected a table")
      return
    }
    for cell in node.cells {
      let widest = widestWordTypesetAlone(cell.text.text)
      #expect(cell.textFrame.width >= widest - 1 / grid.scale - 0.001)
      #expect(cell.text.lines.allSatisfy { line in
        // No word got split: each line ends at whitespace or the end of the cell.
        let string = cell.text.text.attributedString.string as NSString
        let end = NSMaxRange(line.range)
        guard end < string.length else { return true }
        let last = string.character(at: end - 1)
        return last == 0x20 || last == 0x0A
      })
    }
  }

  // MARK: - Cache

  @Test("The cache evicts the least recently used entry first")
  func cacheEvictsLeastRecentlyUsed() {
    // Four 7-character entries fill the budget exactly; a fifth evicts one.
    let cache = TextLayoutCache(characterBudget: 28)
    let texts = (0 ..< 5).map { Fixtures.text("Entry \($0)") }
    var first: [TextLayout] = []
    for text in texts.prefix(4) {
      first.append(cache.layout(text, maximumWidth: 200, grid: grid))
    }
    #expect(cache.count == 4)
    // Touch the oldest so the second becomes least recently used.
    _ = cache.layout(texts[0], maximumWidth: 200, grid: grid)
    _ = cache.layout(texts[4], maximumWidth: 200, grid: grid)
    #expect(cache.count == 4)
    for kept in [0, 2, 3] {
      let again = cache.layout(texts[kept], maximumWidth: 200, grid: grid)
      #expect(again.lines.first?.ctLine === first[kept].lines.first?.ctLine, "entry \(kept) should still be cached")
    }
    // The second was evicted, so it is typeset again.
    let again1 = cache.layout(texts[1], maximumWidth: 200, grid: grid)
    #expect(again1.lines.first?.ctLine !== first[1].lines.first?.ctLine)
  }

  @Test("Eviction keeps the cache within budget across many entries")
  func cacheStaysWithinBudget() {
    let cache = TextLayoutCache(characterBudget: 1_000)
    for index in 0 ..< 2_000 {
      _ = cache.layout(Fixtures.text("Row \(index) of a long list"), maximumWidth: 300, grid: grid)
    }
    // Each entry is at least 20 characters.
    #expect(cache.count <= 1_000 / 20)
    #expect(cache.count > 0)
    cache.removeAll()
    #expect(cache.count == 0)
    _ = cache.layout(Fixtures.text("After clearing"), maximumWidth: 300, grid: grid)
    #expect(cache.count == 1)
  }

  @Test("A streamed message keeps one entry per width, not one per edit")
  func streamingReplacesPreviousVersion() {
    let cache = TextLayoutCache()
    let message = String(repeating: "Streaming words arrive a few at a time. ", count: 20)
    let other = Fixtures.text("Unrelated row")
    _ = cache.layout(other, maximumWidth: 300, grid: grid)
    var revealed = 0
    while revealed < message.count {
      revealed = min(message.count, revealed + 10)
      let text = Fixtures.text(String(message.prefix(revealed)))
      _ = cache.layout(text, maximumWidth: 300, grid: grid)
      // The same text at another width, as a second plan of the row would ask.
      _ = cache.layout(text, maximumWidth: 200, grid: grid)
    }
    #expect(cache.count == 3)
    let otherAgain = cache.layout(other, maximumWidth: 300, grid: grid)
    #expect(otherAgain.lines.count == 1)
    #expect(cache.count == 3)
  }

  @Test("Text that only shares a start with an earlier entry is kept")
  func streamingLeavesUnrelatedTextAlone() {
    let cache = TextLayoutCache()
    let short = cache.layout(Fixtures.text("Hello"), maximumWidth: 300, grid: grid)
    // Same start, different width: not an earlier version of the same layout.
    _ = cache.layout(Fixtures.text("Hello there"), maximumWidth: 200, grid: grid)
    // Diverging text.
    _ = cache.layout(Fixtures.text("Help"), maximumWidth: 300, grid: grid)
    #expect(cache.count == 3)
    #expect(cache.layout(Fixtures.text("Hello"), maximumWidth: 300, grid: grid).lines.first?.ctLine === short.lines.first?.ctLine)
  }

  @Test("Concurrent cache use stays consistent")
  func cacheConcurrency() async {
    let cache = TextLayoutCache(characterBudget: 600)
    let grid = grid
    await withTaskGroup(of: Void.self) { group in
      for worker in 0 ..< 8 {
        group.addTask {
          for index in 0 ..< 300 {
            let text = Fixtures.text("Worker \(worker % 3) row \(index % 40)")
            let layout = cache.layout(text, maximumWidth: 200, grid: grid)
            #expect(layout.length == text.length)
          }
        }
      }
    }
    // Each text is at least 14 characters.
    #expect(cache.count <= 600 / 14)
    #expect(cache.count > 0)
  }

  // MARK: - MessageText

  @Test("Text equality and hashing agree")
  func messageTextHashing() {
    let long = String(repeating: "abcdefghij", count: 300) // spans several hash chunks
    let a = Fixtures.text(long + "x")
    let b = Fixtures.text(long + "x")
    let c = Fixtures.text(long + "y")
    #expect(a == b)
    #expect(a.hashValue == b.hashValue)
    #expect(a != c)
    #expect(a.hashValue != c.hashValue)
    // Same characters, different attributes: equal hashes are fine, equality is not.
    let small = Fixtures.text("Same", font: Fixtures.caption)
    let large = Fixtures.text("Same", font: Fixtures.body)
    #expect(small != large)
    #expect(small.hashValue == large.hashValue)
    // Composed and decomposed forms are different code units, so different texts.
    #expect(Fixtures.text("\u{00E9}") != Fixtures.text("e\u{0301}"))
    #expect(Fixtures.text("") == MessageText(NSAttributedString()))
    // A mutable source is copied, so later edits don't change the text or its hash.
    let source = NSMutableAttributedString(string: "Mutable")
    let copied = MessageText(source)
    let hash = copied.hashValue
    source.append(NSAttributedString(string: " changed"))
    #expect(copied.string == "Mutable")
    #expect(copied.hashValue == hash)
    #expect(copied == MessageText(NSAttributedString(string: "Mutable")))
  }

  // MARK: - Glyph positions

  /// The glyph extents `LineStorage` used to build when the line was made.
  func eagerGlyphs(_ line: CTLine) -> [[LineStorage.Glyph]] {
    (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).map { run in
      let count = CTRunGetGlyphCount(run)
      guard count > 0 else { return [] }
      var positions = [CGPoint](repeating: .zero, count: count)
      var advances = [CGSize](repeating: .zero, count: count)
      var indices = [CFIndex](repeating: 0, count: count)
      CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
      CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
      CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
      return (0 ..< count).map {
        LineStorage.Glyph(stringIndex: indices[$0], minX: positions[$0].x, maxX: positions[$0].x + advances[$0].width)
      }
    }
  }

  @Test("Highlights starting on a negatively kerned Arabic glyph don't trap")
  func negativeAdvanceRects() {
    let text = Fixtures.text("سلام دنیا")
    let layout = TextLayouter.layout(text, maximumWidth: 300, grid: grid)
    for location in 0 ..< text.length {
      for rect in layout.rects(for: NSRange(location: location, length: 1)) {
        #expect(rect.width >= 0)
      }
    }
  }

  @Test("Glyph positions read lazily match the line, from any thread")
  func lazyGlyphs() async {
    let text = Fixtures.text("Hello world, سلام دنیا. Mixed 👍🏽 text that wraps onto several lines for hit testing.")
    let layout = TextLayouter.layout(text, maximumWidth: 160, grid: grid)
    #expect(layout.lineCount > 1)
    let expected = layout.lines.map { eagerGlyphs($0.ctLine) }
    let points = stride(from: 0, to: layout.size.height, by: 3).flatMap { y in
      stride(from: 0, to: layout.size.width, by: 4).map { CGPoint(x: $0, y: y) }
    }
    let ranges = (0 ..< text.length).map { NSRange(location: $0, length: min(7, text.length - $0)) }

    // Many readers race to build each line's glyphs; all must see the same result.
    let results = await withTaskGroup(of: ([Int?], [[CGRect]]).self) { group in
      for _ in 0 ..< 8 {
        group.addTask {
          (points.map { layout.characterIndex(at: $0) }, ranges.map { layout.rects(for: $0) })
        }
      }
      var all: [([Int?], [[CGRect]])] = []
      for await result in group { all.append(result) }
      return all
    }
    for result in results.dropFirst() {
      #expect(result.0 == results[0].0)
      #expect(result.1 == results[0].1)
    }
    for (line, glyphs) in zip(layout.lines, expected) {
      let built = line.storage.runs.map(\.glyphs)
      #expect(built.count == glyphs.count)
      for (a, b) in zip(built, glyphs) {
        #expect(a.map(\.stringIndex) == b.map(\.stringIndex))
        #expect(a.map(\.minX) == b.map(\.minX))
        #expect(a.map(\.maxX) == b.map(\.maxX))
      }
    }
    #expect(results[0].0.contains { $0 != nil })
  }
}
