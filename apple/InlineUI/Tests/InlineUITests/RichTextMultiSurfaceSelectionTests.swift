import Foundation
import Testing
@testable import TextProcessing

@Suite("Rich text multi-surface selection")
struct RichTextMultiSurfaceSelectionTests {
  typealias Endpoint = RichTextMultiSurfaceSelection.Endpoint
  typealias DocumentItem = RichTextMultiSurfaceSelection.DocumentItem

  @Test("plans partial endpoints and complete intermediate surfaces")
  func plansForwardSelection() throws {
    let ranges = try #require(RichTextMultiSurfaceSelection.ranges(
      surfaceLengths: [5, 4, 6],
      anchor: Endpoint(surfaceIndex: 0, utf16Offset: 2),
      head: Endpoint(surfaceIndex: 2, utf16Offset: 3)
    ))

    #expect(ranges == [NSRange(location: 2, length: 3), NSRange(location: 0, length: 4), NSRange(location: 0, length: 3)])
  }

  @Test("reverse drags produce the same document-order ranges")
  func normalizesReverseSelection() throws {
    let forward = try #require(RichTextMultiSurfaceSelection.ranges(
      surfaceLengths: [5, 4, 6],
      anchor: Endpoint(surfaceIndex: 0, utf16Offset: 2),
      head: Endpoint(surfaceIndex: 2, utf16Offset: 3)
    ))
    let reverse = try #require(RichTextMultiSurfaceSelection.ranges(
      surfaceLengths: [5, 4, 6],
      anchor: Endpoint(surfaceIndex: 2, utf16Offset: 3),
      head: Endpoint(surfaceIndex: 0, utf16Offset: 2)
    ))

    #expect(reverse == forward)
  }

  @Test("same-surface selection and caret ranges stay local")
  func plansSameSurfaceSelection() throws {
    let selection = try #require(RichTextMultiSurfaceSelection.ranges(
      surfaceLengths: [3, 8, 2],
      anchor: Endpoint(surfaceIndex: 1, utf16Offset: 6),
      head: Endpoint(surfaceIndex: 1, utf16Offset: 2)
    ))
    let caret = try #require(RichTextMultiSurfaceSelection.ranges(
      surfaceLengths: [3],
      anchor: Endpoint(surfaceIndex: 0, utf16Offset: 2),
      head: Endpoint(surfaceIndex: 0, utf16Offset: 2)
    ))

    #expect(selection == [nil, NSRange(location: 2, length: 4), nil])
    #expect(caret == [NSRange(location: 2, length: 0)])
  }

  @Test("clamps native endpoints and preserves empty intermediate blocks")
  func clampsEndpoints() throws {
    let ranges = try #require(RichTextMultiSurfaceSelection.ranges(
      surfaceLengths: [2, 0, 4],
      anchor: Endpoint(surfaceIndex: 0, utf16Offset: -20),
      head: Endpoint(surfaceIndex: 2, utf16Offset: 20)
    ))

    #expect(ranges == [NSRange(location: 0, length: 2), NSRange(location: 0, length: 0), NSRange(location: 0, length: 4)])
  }

  @Test("invalid surface topology fails closed")
  func rejectsInvalidTopology() {
    #expect(RichTextMultiSurfaceSelection.ranges(
      surfaceLengths: [],
      anchor: Endpoint(surfaceIndex: 0, utf16Offset: 0),
      head: Endpoint(surfaceIndex: 0, utf16Offset: 0)
    ) == nil)
    #expect(RichTextMultiSurfaceSelection.ranges(
      surfaceLengths: [4, -1],
      anchor: Endpoint(surfaceIndex: 0, utf16Offset: 0),
      head: Endpoint(surfaceIndex: 1, utf16Offset: 0)
    ) == nil)
    #expect(RichTextMultiSurfaceSelection.ranges(
      surfaceLengths: [4],
      anchor: Endpoint(surfaceIndex: 1, utf16Offset: 0),
      head: Endpoint(surfaceIndex: 0, utf16Offset: 0)
    ) == nil)
  }

  @Test("semantic export preserves list markers and excludes them for a partial item selection")
  func exportsListMarkerSemantics() throws {
    let document = [
      DocumentItem(content: .literal(0, leadingForSurface: 0), separatorAfter: " "),
      DocumentItem(content: .surface(0), separatorAfter: "\n"),
    ]
    let text = [NSAttributedString(string: "item")]
    let marker = [NSAttributedString(string: "•")]

    let full = try #require(RichTextMultiSurfaceSelection.attributedText(
      document: document,
      surfaceTexts: text,
      surfaceRanges: [NSRange(location: 0, length: 4)],
      literals: marker
    ))
    let partial = try #require(RichTextMultiSurfaceSelection.attributedText(
      document: document,
      surfaceTexts: text,
      surfaceRanges: [NSRange(location: 1, length: 3)],
      literals: marker
    ))

    #expect(full.string == "• item")
    #expect(partial.string == "tem")
  }

  @Test("semantic export uses tabs within table rows and newlines between rows")
  func exportsTableSemantics() throws {
    let document = [
      DocumentItem(content: .surface(0), separatorAfter: "\t"),
      DocumentItem(content: .surface(1), separatorAfter: "\n"),
      DocumentItem(content: .surface(2), separatorAfter: "\t"),
      DocumentItem(content: .surface(3), separatorAfter: "\n"),
    ]
    let cells = ["a", "b", "c", "d"].map { NSAttributedString(string: $0) }
    let ranges: [NSRange?] = cells.map { NSRange(location: 0, length: $0.length) }

    let result = try #require(RichTextMultiSurfaceSelection.attributedText(
      document: document,
      surfaceTexts: cells,
      surfaceRanges: ranges,
      literals: []
    ))
    #expect(result.string == "a\tb\nc\td")
  }

  @Test("a boundary-only cross-surface selection exports its semantic delimiter")
  func exportsBoundaryDelimiter() throws {
    let document = [
      DocumentItem(content: .surface(0), separatorAfter: "\t"),
      DocumentItem(content: .surface(1), separatorAfter: "\n"),
    ]
    let result = try #require(RichTextMultiSurfaceSelection.attributedText(
      document: document,
      surfaceTexts: [NSAttributedString(string: "a"), NSAttributedString(string: "b")],
      surfaceRanges: [NSRange(location: 1, length: 0), NSRange(location: 0, length: 0)],
      literals: []
    ))
    #expect(result.string == "\t")
  }

  @Test("rendered math source and inline attributes survive a spanning export")
  func exportsRenderedMathAndAttributes() throws {
    let style = NSAttributedString.Key("selection-test-style")
    let first = NSAttributedString(string: "before", attributes: [style: "kept"])
    let second = NSAttributedString(string: "after")
    let document = [
      DocumentItem(content: .surface(0), separatorAfter: "\n"),
      DocumentItem(content: .literal(0, leadingForSurface: nil), separatorAfter: "\n"),
      DocumentItem(content: .surface(1), separatorAfter: "\n"),
    ]
    let forward: [NSRange?] = [NSRange(location: 2, length: 4), NSRange(location: 0, length: 2)]
    let result = try #require(RichTextMultiSurfaceSelection.attributedText(
      document: document,
      surfaceTexts: [first, second],
      surfaceRanges: forward,
      literals: [NSAttributedString(string: "x^2")]
    ))

    #expect(result.string == "fore\nx^2\naf")
    #expect(result.attribute(style, at: 0, effectiveRange: nil) as? String == "kept")
  }

  @Test("select all includes leading markers and trailing rendered math")
  func selectAllIncludesDocumentEdges() throws {
    let document = [
      DocumentItem(content: .literal(0, leadingForSurface: 0), separatorAfter: " "),
      DocumentItem(content: .surface(0), separatorAfter: "\n"),
      DocumentItem(content: .literal(1, leadingForSurface: nil), separatorAfter: "\n"),
    ]
    let result = try #require(RichTextMultiSurfaceSelection.attributedText(
      document: document,
      surfaceTexts: [NSAttributedString(string: "item")],
      surfaceRanges: [NSRange(location: 0, length: 4)],
      literals: [NSAttributedString(string: "1."), NSAttributedString(string: "x+y")],
      includeDocumentEdges: true
    ))
    #expect(result.string == "1. item\nx+y")
  }

  @Test("malformed semantic documents and split-surrogate ranges fail closed")
  func rejectsMalformedSemanticDocument() {
    let text = [NSAttributedString(string: "😀")]
    let ranges: [NSRange?] = [NSRange(location: 1, length: 1)]
    let malformedDocuments: [[DocumentItem]] = [
      [DocumentItem(content: .surface(1), separatorAfter: "")],
      [DocumentItem(content: .surface(0), separatorAfter: ""),
       DocumentItem(content: .surface(0), separatorAfter: "")],
      [DocumentItem(content: .literal(-1, leadingForSurface: nil), separatorAfter: ""),
       DocumentItem(content: .surface(0), separatorAfter: "")],
    ]

    for document in malformedDocuments {
      #expect(RichTextMultiSurfaceSelection.attributedText(
        document: document,
        surfaceTexts: text,
        surfaceRanges: ranges,
        literals: []
      ) == nil)
    }
    #expect(RichTextMultiSurfaceSelection.attributedText(
      document: [DocumentItem(content: .surface(0), separatorAfter: "")],
      surfaceTexts: text,
      surfaceRanges: ranges,
      literals: []
    ) == nil)
  }

  @Test("discontiguous ranges and reordered surfaces cannot manufacture a continuous selection")
  func rejectsDiscontiguousRanges() {
    let document = (0 ..< 3).map { DocumentItem(content: .surface($0), separatorAfter: "\n") }
    let full = NSRange(location: 0, length: 1)
    #expect(RichTextMultiSurfaceSelection.documentParts(
      document: document, surfaceRanges: [full, nil, full]
    ) == nil)
    #expect(RichTextMultiSurfaceSelection.documentParts(
      document: [document[1], document[0], document[2]], surfaceRanges: [full, full, full]
    ) == nil)
  }

  @Test("select all retains empty cells at both edges of a table")
  func selectAllRetainsEmptyCells() throws {
    let texts = ["", "b", ""].map { NSAttributedString(string: $0) }
    let ranges = try #require(RichTextMultiSurfaceSelection.ranges(
      surfaceLengths: texts.map(\.length),
      anchor: .init(surfaceIndex: 0, utf16Offset: 0),
      head: .init(surfaceIndex: 2, utf16Offset: 0)
    ))
    let selected = try #require(RichTextMultiSurfaceSelection.attributedText(
      document: (0 ..< 3).map { DocumentItem(content: .surface($0), separatorAfter: "\t") },
      surfaceTexts: texts, surfaceRanges: ranges, literals: [], includeDocumentEdges: true
    ))
    #expect(selected.string == "\tb\t")
  }
}
