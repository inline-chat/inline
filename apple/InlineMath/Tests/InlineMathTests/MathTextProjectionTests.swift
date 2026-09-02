import Foundation
import Testing
@testable import InlineMath

@Suite("Math source and display ranges")
struct MathTextProjectionTests {
  @Test("Unicode, multiple formulas, selection and copy retain canonical source")
  func selectionAndCopy() throws {
    let source = #"😀 x^2 + \frac{a}{b} fin"#
    let first = (source as NSString).range(of: "x^2")
    let second = (source as NSString).range(of: #"\frac{a}{b}"#)
    let projection = try #require(MathTextProjection(source: source, renderedRanges: [second, first]))
    #expect(projection.source == source)
    #expect(projection.text == "😀 \u{fffc} + \u{fffc} fin")
    #expect(projection.sourceText(forDisplayRange: NSRange(location: 0, length: (projection.text as NSString).length)) == source)
    #expect(projection.sourceText(forDisplayRange: NSRange(location: 3, length: 1)) == "x^2")
    #expect(projection.sourceText(forDisplayRange: NSRange(location: 7, length: 1)) == #"\frac{a}{b}"#)
    #expect(projection.sourceText(forDisplayRange: NSRange(location: 3, length: 5)) == #"x^2 + \frac{a}{b}"#)
    #expect(projection.displayRange(forSourceRange: second) == NSRange(location: 7, length: 1))
    #expect(projection.displayRange(forSourceRange: NSRange(location: 4, length: 1)) == NSRange(location: 3, length: 1))
    #expect(projection.displayRange(forSourceRange: NSRange(location: 4, length: 0)) == NSRange(location: 3, length: 0))
    #expect(projection.sourceRange(forDisplayRange: NSRange(location: 4, length: 0)) == NSRange(location: 6, length: 0))
  }

  @Test("adjacent formulas remain distinct occurrences")
  func adjacent() throws {
    let projection = try #require(MathTextProjection(source: "x^2y^3", renderedRanges: [
      NSRange(location: 0, length: 3), NSRange(location: 3, length: 3),
    ]))
    #expect(projection.text == "\u{fffc}\u{fffc}")
    #expect(projection.sourceText(forDisplayRange: NSRange(location: 1, length: 1)) == "y^3")
    #expect(projection.sourceText(forDisplayRange: NSRange(location: 0, length: 1)) == "x^2")
    #expect(projection.sourceText(forDisplayRange: NSRange(location: 1, length: 0)) == "")
  }

  @Test("invalid ranges never clamp, overflow or split surrogate pairs")
  func invalidRanges() throws {
    for range in [NSRange(location: -1, length: 1), NSRange(location: 0, length: 0),
                  NSRange(location: 0, length: Int.max), NSRange(location: Int.max, length: 1),
                  NSRange(location: 1, length: 1), NSRange(location: 0, length: 1)] {
      #expect(MathTextProjection(source: "😀x", renderedRanges: [range]) == nil)
    }
    #expect(MathTextProjection(source: "abc", renderedRanges: [NSRange(location: 0, length: 2), NSRange(location: 1, length: 2)]) == nil)
    #expect(MathTextProjection(source: String(repeating: "x", count: 65), renderedRanges: (0..<65).map { NSRange(location: $0, length: 1) }) == nil)
    let plain = try #require(MathTextProjection(source: "😀x", renderedRanges: []))
    #expect(plain.sourceRange(forDisplayRange: NSRange(location: 1, length: 1)) == nil)
    #expect(plain.displayRange(forSourceRange: NSRange(location: 0, length: 1)) == nil)
    #expect(plain.sourceRange(forDisplayRange: NSRange(location: 3, length: Int.max)) == nil)
  }

  @Test("unrendered and canonically equivalent text is preserved literally")
  func literalSource() throws {
    for source in ["", "é x", "e\u{301} x", "😀x"] {
      let plain = try #require(MathTextProjection(source: source, renderedRanges: []))
      #expect(plain.text.utf8.elementsEqual(source.utf8))
      #expect(plain.sourceText(forDisplayRange: NSRange(location: 0, length: (source as NSString).length))?.utf8.elementsEqual(source.utf8) == true)
    }
  }
}
