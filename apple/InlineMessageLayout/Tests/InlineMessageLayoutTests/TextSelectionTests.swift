import CoreGraphics
import Foundation
import Testing
@testable import InlineMessageLayout

@Suite("Text selection")
struct TextSelectionTests {
  let grid = Fixtures.grid

  private func layout(_ string: String, width: CGFloat = 300) -> TextLayout {
    TextLayouter.layout(Fixtures.text(string), maximumWidth: width, grid: grid)
  }

  @Test("The closest caret clamps to the text's ends")
  func closestCaretAtEdges() throws {
    let text = layout("Hello world")
    let line = try #require(text.lines.first)
    #expect(text.closestCaretIndex(to: CGPoint(x: -20, y: line.frame.midY)) == 0)
    #expect(text.closestCaretIndex(to: CGPoint(x: 1000, y: line.frame.midY)) == 11)
    #expect(text.closestCaretIndex(to: CGPoint(x: -20, y: -50)) == 0)
    #expect(text.closestCaretIndex(to: CGPoint(x: 1000, y: 1000)) == 11)
    #expect(layout("").closestCaretIndex(to: .zero) == 0)
  }

  @Test("A point just inside a letter's leading half picks the caret before it")
  func closestCaretInside() throws {
    let text = layout("Hello world")
    let caret = try #require(text.caretRect(at: 6))
    #expect(text.closestCaretIndex(to: CGPoint(x: caret.minX + 1, y: caret.midY)) == 6)
    #expect(text.closestCaretIndex(to: CGPoint(x: caret.minX - 1, y: caret.midY)) == 6)
  }

  @Test("Caret rects run from the line start to its typographic end")
  func caretRects() throws {
    let text = layout("Hello world")
    let line = try #require(text.lines.first)
    let start = try #require(text.caretRect(at: 0))
    let end = try #require(text.caretRect(at: 11))
    #expect(abs(start.minX) < 0.5)
    #expect(abs(end.minX - line.frame.width) < 0.5)
    #expect(start.height == line.frame.height && start.width == 0)
  }

  @Test("A caret never lands after a hard break")
  func caretStopsBeforeBreak() throws {
    let text = layout("One\nTwo")
    #expect(text.lineCount == 2)
    let first = text.lines[0]
    #expect(text.closestCaretIndex(to: CGPoint(x: 1000, y: first.frame.midY)) == 3)
    let next = try #require(text.caretRect(at: 4))
    #expect(next.minY == text.lines[1].frame.minY)
    let end = try #require(text.caretRect(at: 3, affinity: .upstream))
    #expect(end.minY == first.frame.minY)
  }

  @Test("At a soft wrap, upstream carets end the earlier line and downstream ones start the next")
  func softWrapAffinity() throws {
    let text = layout(String(repeating: "wrap these words ", count: 4), width: 120)
    #expect(text.lineCount > 1)
    let boundary = text.lines[1].range.location
    let upstream = try #require(text.caretRect(at: boundary, affinity: .upstream))
    let downstream = try #require(text.caretRect(at: boundary, affinity: .downstream))
    #expect(upstream.minY == text.lines[0].frame.minY)
    #expect(downstream.minY == text.lines[1].frame.minY)
  }

  @Test("Words come from word boundaries; anything else selects its cluster")
  func words() {
    let text = layout("Hello world, 👍 ok")
    #expect(text.wordRange(at: 7) == NSRange(location: 6, length: 5))
    #expect(text.wordRange(at: 0) == NSRange(location: 0, length: 5))
    #expect(text.wordRange(at: 5) == NSRange(location: 5, length: 1))
    let thumb = ("Hello world, 👍 ok" as NSString).range(of: "👍")
    #expect(text.wordRange(at: thumb.location + 1) == thumb)
    #expect(text.string(in: NSRange(location: 6, length: 5)) == "world")
  }

  @Test("Selections widen to whole clusters")
  func clusters() {
    let text = layout("a👍b")
    #expect(text.selectionRange(from: 2, to: 1) == NSRange(location: 1, length: 2))
    #expect(text.selectionRange(from: 3, to: 3) == NSRange(location: 3, length: 0))
    #expect(text.selectionRange(from: -4, to: 100) == NSRange(location: 0, length: 4))
  }

  @Test("A press selects the word whose glyph is under it, or the line's last word past its end")
  func pressedWord() throws {
    let text = layout("Hello world")
    let afterHello = try #require(text.caretRect(at: 5))
    // The trailing half of the "o": the nearest caret is after it, but the word is "Hello".
    #expect(text.wordRange(at: CGPoint(x: afterHello.minX - 1, y: afterHello.midY)) == NSRange(location: 0, length: 5))
    let world = try #require(text.caretRect(at: 8))
    #expect(text.wordRange(at: CGPoint(x: world.minX + 1, y: world.midY)) == NSRange(location: 6, length: 5))

    let lines = layout("One\nTwo")
    let first = lines.lines[0]
    #expect(lines.wordRange(at: CGPoint(x: 1000, y: first.frame.midY)) == NSRange(location: 0, length: 3))
  }

  @Test("Selection highlights follow glyphs, even across a change of direction")
  func highlights() throws {
    let single = layout("Hello world")
    let line = try #require(single.lines.first)
    let all = single.rects(for: NSRange(location: 0, length: 11))
    #expect(all.count == 1)
    #expect(abs(all[0].minX) < 0.5 && abs(all[0].width - line.frame.width) < 0.5)
    #expect(single.rects(for: NSRange(location: 3, length: 0)).isEmpty)

    let wrapped = layout("One two\nThree four", width: 300)
    let rects = wrapped.rects(for: NSRange(location: 4, length: 9))
    let two = try #require(wrapped.caretRect(at: 4))
    #expect(rects.first.map { abs($0.minX - two.minX) < 0.5 && $0.minY == wrapped.lines[0].frame.minY } == true)
    #expect(rects.last.map { abs($0.minX) < 0.5 && $0.minY == wrapped.lines[1].frame.minY } == true)

    // "c אב" in "abc אבג def": the Hebrew word draws right to left, so the unselected "ג" sits
    // visually between the selected space and "ב".
    let mixed = layout("abc אבג def")
    let selection = mixed.rects(for: NSRange(location: 2, length: 4))
    func center(_ index: Int) throws -> CGPoint {
      let glyph = try #require(mixed.rects(for: NSRange(location: index, length: 1)).first)
      return CGPoint(x: glyph.midX, y: glyph.midY)
    }
    let covers = { (point: CGPoint) in selection.contains { $0.contains(point) } }
    #expect(try covers(center(2)))
    #expect(try covers(center(4)))
    #expect(try !covers(center(6)))
  }
}
