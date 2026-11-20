import CoreGraphics
import Foundation
import Testing
@testable import InlineMessageLayout

@Suite("Text selection across surfaces")
struct TextSelectionSurfacesTests {
  let grid = Fixtures.grid

  private func layout(_ string: String, width: CGFloat = 300) -> TextLayout {
    TextLayouter.layout(Fixtures.text(string), maximumWidth: width, grid: grid)
  }

  private func place(_ surfaces: TextSelectionSurfaces, _ index: Int, _ affinity: TextCaretAffinity) -> [Int] {
    surfaces.location(of: index, affinity: affinity).map { [$0.surface, $0.offset] } ?? []
  }

  /// "Hello world" above "Second block" with a 10 pt gap, like two paragraphs.
  private func paragraphs() -> TextSelectionSurfaces {
    let first = layout("Hello world")
    let second = layout("Second block")
    return TextSelectionSurfaces([
      .init(layout: first, origin: CGPoint(x: 10, y: 20)),
      .init(layout: second, origin: CGPoint(x: 10, y: 20 + first.size.height + 10)),
    ])
  }

  @Test("Flat indices join surfaces end to end, and affinity picks a side of the seam")
  func flatIndex() throws {
    let surfaces = paragraphs()
    #expect(surfaces.length == 23)
    #expect(surfaces.starts == [0, 11])
    #expect(place(surfaces, 11, .downstream) == [1, 0])
    #expect(place(surfaces, 11, .upstream) == [0, 11])
    #expect(place(surfaces, 0, .upstream) == [0, 0])
    #expect(place(surfaces, 23, .downstream) == [1, 12])
    #expect(surfaces.string(in: NSRange(location: 6, length: 11)) == "worldSecond")
    #expect(surfaces.surfaceRanges(for: NSRange(location: 6, length: 11)) == [
      NSRange(location: 6, length: 5), NSRange(location: 0, length: 6),
    ])
    // Ending at the seam leaves the next surface out.
    #expect(surfaces.surfaceRanges(for: NSRange(location: 0, length: 11)) == [NSRange(location: 0, length: 11), nil])
  }

  @Test("A drag between blocks goes to the nearer one; a press needs text within its padding")
  func hitTesting() throws {
    let surfaces = paragraphs()
    let first = try #require(surfaces.surfaces[0].frame)
    let second = try #require(surfaces.surfaces[1].frame)
    #expect(surfaces.nearestSurface(to: CGPoint(x: 20, y: first.maxY + 2)) == 0)
    #expect(surfaces.nearestSurface(to: CGPoint(x: 20, y: second.minY - 2)) == 1)
    #expect(surfaces.nearestSurface(to: CGPoint(x: 500, y: second.midY)) == 1)
    #expect(surfaces.nearestSurface(to: CGPoint(x: 20, y: -100)) == 0)
    #expect(surfaces.surface(at: CGPoint(x: first.minX - 6, y: first.midY), padding: 8) == 0)
    #expect(surfaces.surface(at: CGPoint(x: first.minX - 20, y: first.midY), padding: 8) == nil)
    // Past the first block's end, on the next block's row: the end of "Second block".
    #expect(surfaces.closestIndex(to: CGPoint(x: 1000, y: second.midY)) == 23)
    #expect(surfaces.wordRange(at: CGPoint(x: second.minX + 2, y: second.midY), padding: 8) == NSRange(location: 11, length: 6))
  }

  @Test("A press on the space between words takes the nearer word")
  func pressOnSpace() throws {
    let text = layout("Hello   world")
    let surfaces = TextSelectionSurfaces(layout: text, origin: .zero)
    let hello = try #require(text.caretRect(at: 5))
    let world = try #require(text.caretRect(at: 8))
    let nearHello = CGPoint(x: hello.minX + 1, y: hello.midY)
    let nearWorld = CGPoint(x: world.minX - 1, y: world.midY)
    #expect(surfaces.wordRange(at: nearHello, padding: 8) == NSRange(location: 0, length: 5))
    #expect(surfaces.wordRange(at: nearWorld, padding: 8) == NSRange(location: 8, length: 5))
    // A few points above the line, inside the press padding.
    let above = CGPoint(x: world.minX - 1, y: world.minY - 6)
    #expect(surfaces.wordRange(at: above, padding: 8) == NSRange(location: 8, length: 5))
  }

  @Test("Cells on one row are told apart sideways")
  func tableRow() throws {
    let left = layout("Left")
    let right = layout("Right")
    let surfaces = TextSelectionSurfaces([
      .init(layout: left, origin: CGPoint(x: 0, y: 0)),
      .init(layout: right, origin: CGPoint(x: 120, y: 0)),
    ])
    #expect(surfaces.nearestSurface(to: CGPoint(x: 100, y: 5)) == 1)
    #expect(surfaces.nearestSurface(to: CGPoint(x: 50, y: 5)) == 0)
  }

  @Test("Selections widen to whole clusters at both ends, across surfaces")
  func clusters() {
    let surfaces = TextSelectionSurfaces([
      .init(layout: layout("a👍"), origin: .zero),
      .init(layout: layout("👍b"), origin: CGPoint(x: 0, y: 40)),
    ])
    // Mid-emoji in the first surface to mid-emoji in the second.
    #expect(surfaces.selectionRange(from: 2, to: 4) == NSRange(location: 1, length: 4))
    #expect(surfaces.selectionRange(from: 3, to: 3).length == 0)
  }

  @Test("Highlights close small line gaps and stop at a scrolling box's edge")
  func highlights() throws {
    let wrapped = layout(String(repeating: "wrap these words ", count: 4), width: 120)
    #expect(wrapped.lineCount > 1)
    let surfaces = TextSelectionSurfaces(layout: wrapped, origin: CGPoint(x: 5, y: 5))
    let rects = surfaces.highlightRects(for: NSRange(location: 0, length: wrapped.length))
    for (upper, lower) in zip(rects, rects.dropFirst()) {
      #expect(lower.minY - upper.maxY <= 0.01)
    }

    let code = layout("let value = someLongFunctionName(argument)", width: .greatestFiniteMagnitude)
    let box = CGRect(x: 0, y: 0, width: 60, height: 40)
    let clipped = TextSelectionSurfaces([.init(layout: code, origin: CGPoint(x: 8, y: 8), visibleRect: box)])
    let highlight = clipped.highlightRects(for: NSRange(location: 0, length: code.length))
    #expect(highlight.allSatisfy { $0.maxX <= box.maxX + 0.01 })
    // The end caret is scrolled out of the box, so it has no handle.
    #expect(clipped.caretRect(at: code.length, affinity: .upstream) == nil)
    #expect(clipped.caretRect(at: 0, affinity: .downstream) != nil)
    // Dragging past the box's edge stops at the last caret that shows.
    let index = clipped.closestIndex(to: CGPoint(x: 500, y: 10))
    let caret = try #require(clipped.caretRect(at: index, affinity: .upstream))
    #expect(caret.midX <= box.maxX + 1)
  }

  @Test("Empty surfaces hold no caret but keep their place")
  func emptySurfaces() {
    let surfaces = TextSelectionSurfaces([
      .init(layout: layout("One"), origin: .zero),
      .init(layout: .empty, origin: CGPoint(x: 0, y: 30)),
      .init(layout: layout("Two"), origin: CGPoint(x: 0, y: 60)),
    ])
    #expect(surfaces.length == 6)
    #expect(place(surfaces, 3, .downstream) == [2, 0])
    #expect(place(surfaces, 3, .upstream) == [0, 3])
    #expect(surfaces.surfaceRanges(for: NSRange(location: 0, length: 6)) == [
      NSRange(location: 0, length: 3), NSRange(location: 0, length: 0), NSRange(location: 0, length: 3),
    ])
  }
}
