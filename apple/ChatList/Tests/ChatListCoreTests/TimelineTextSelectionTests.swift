import Foundation
@testable import ChatListCore
import Testing

struct TimelineTextSelectionTests {
  private typealias Document = TimelineTextSelection<String>

  private func document(_ entries: [Document.Entry]) throws -> Document {
    try #require(Document(entries: entries))
  }

  private func endpoint(
    _ key: String, _ offset: Int, _ affinity: Document.Affinity = .downstream
  ) -> Document.Endpoint {
    Document.Endpoint(key: key, utf16Offset: offset, affinity: affinity)
  }

  @Test func `reverse selection keeps logical range order`() throws {
    let document = try document([
      .surface(key: "a", text: "alpha"), .surface(key: "b", text: "bravo"), .surface(key: "c", text: "charlie"),
    ])
    let selection = try #require(document.project(anchor: endpoint("c", 4), head: endpoint("a", 2)))
    #expect(selection.anchor == endpoint("c", 4))
    #expect(selection.head == endpoint("a", 2))
    #expect(selection.orderedKeys == ["a", "b", "c"])
    #expect(selection.ranges == [
      "a": NSRange(location: 2, length: 3), "b": NSRange(location: 0, length: 5), "c": NSRange(location: 0, length: 4),
    ])
  }

  @Test func `zero selection and empty surfaces have no ranges`() throws {
    let document = try document([.surface(key: "a", text: "abc"), .surface(key: "empty", text: "")])
    let caret = try #require(document.project(anchor: endpoint("a", 1), head: endpoint("a", 1)))
    #expect(caret.isEmpty)
    #expect(caret.ranges.isEmpty)
    let empty = try #require(document.project(anchor: endpoint("empty", 99), head: endpoint("empty", -99)))
    #expect(empty.isEmpty)
    #expect(empty.anchor.utf16Offset == 0)
    #expect(empty.head.utf16Offset == 0)
    let boundary = try #require(document.project(anchor: endpoint("a", 3), head: endpoint("empty", 0)))
    #expect(boundary.orderedKeys.isEmpty)
  }

  @Test func `out of bounds offsets clamp and missing surfaces fail`() throws {
    let document = try document([.surface(key: "a", text: "abc")])
    let selection = try #require(document.project(anchor: endpoint("a", Int.min), head: endpoint("a", Int.max)))
    #expect(selection.anchor.utf16Offset == 0)
    #expect(selection.head.utf16Offset == 3)
    #expect(selection.ranges["a"] == NSRange(location: 0, length: 3))
    #expect(document.project(anchor: endpoint("absent", 0), head: endpoint("a", 1)) == nil)
    #expect(document.project(anchor: endpoint("a", 0), head: endpoint("absent", 1)) == nil)
  }

  @Test func `copy ranges retain empty interiors and zero length endpoints`() throws {
    let document = try document([
      .surface(key: "a", text: "abc"), .surface(key: "empty", text: ""),
      .surface(key: "middle", text: "selected"), .surface(key: "b", text: "def"),
    ])
    let selection = try #require(document.project(anchor: endpoint("a", 3), head: endpoint("b", 0)))
    #expect(selection.rangesIncludingEmptySurfaces == [
      "a": NSRange(location: 3, length: 0), "empty": NSRange(location: 0, length: 0),
      "middle": NSRange(location: 0, length: 8), "b": NSRange(location: 0, length: 0),
    ])
    #expect(selection.ranges == ["middle": NSRange(location: 0, length: 8)])
    #expect(selection.orderedKeys == ["middle"])
    #expect(!selection.isEmpty)
    let reverse = try #require(document.project(anchor: endpoint("b", 0), head: endpoint("a", 3)))
    #expect(reverse.rangesIncludingEmptySurfaces == selection.rangesIncludingEmptySurfaces)

    let onlyBoundaries = try #require(document.project(anchor: endpoint("a", 3), head: endpoint("empty", 0)))
    #expect(onlyBoundaries.rangesIncludingEmptySurfaces == [
      "a": NSRange(location: 3, length: 0), "empty": NSRange(location: 0, length: 0),
    ])
    #expect(onlyBoundaries.isEmpty)
    #expect(onlyBoundaries.ranges.isEmpty)
    #expect(onlyBoundaries.orderedKeys.isEmpty)
  }

  @Test func `normalization preserves whole emoji and combining graphemes`() throws {
    let text = "A👨‍👩‍👧‍👦e\u{301}🇮🇷Z"
    let document = try document([.surface(key: "a", text: text)])
    // Global UTF-16 boundaries: A 0...1, family 1...12, e+accent
    // 12...14, regional-indicator flag 14...18, Z 18...19.
    for (start, end) in [(1, 12), (12, 14), (14, 18)] {
      for offset in (start + 1) ..< end {
        let upstream = try #require(document.project(anchor: endpoint("a", 0), head: endpoint("a", offset, .upstream)))
        let downstream = try #require(document.project(
          anchor: endpoint("a", 0),
          head: endpoint("a", offset, .downstream)
        ))
        #expect(upstream.head.utf16Offset == start)
        #expect(downstream.head.utf16Offset == end)
      }
    }
    let selection = try #require(document.project(anchor: endpoint("a", 3, .upstream), head: endpoint("a", 13)))
    #expect(selection.anchor.utf16Offset == 1)
    #expect(selection.head.utf16Offset == 14)
    #expect(selection.ranges["a"] == NSRange(location: 1, length: 13))
  }

  @Test func `exact grapheme boundaries stay put and CRLF cannot split`() throws {
    let document = try document([.surface(key: "a", text: "A\r\nB")])
    for affinity in [Document.Affinity.upstream, .downstream] {
      let selection = try #require(document.project(
        anchor: endpoint("a", 1, affinity),
        head: endpoint("a", 3, affinity)
      ))
      #expect(selection.ranges["a"] == NSRange(location: 1, length: 2))
    }
    let selection = try #require(document.project(anchor: endpoint("a", 2, .upstream), head: endpoint("a", 2)))
    #expect(selection.ranges["a"] == NSRange(location: 1, length: 2))
  }

  @Test(arguments: ["\r\n", "\r\n\r\n", "A\rB\nC\r\nD"])
  func `repeated and mixed line breaks preserve only real insertion boundaries`(text: String) throws {
    let document = try document([.surface(key: "a", text: text)])
    let units = Array(text.utf16)
    for offset in 0 ... units.count {
      let splitsPair = offset > 0 && offset < units.count
        && units[offset - 1] == 0x0D && units[offset] == 0x0A
      let selection = try #require(document.project(
        anchor: endpoint("a", offset, .upstream), head: endpoint("a", offset, .downstream)
      ))
      if splitsPair {
        #expect(selection.anchor.utf16Offset == offset - 1)
        #expect(selection.head.utf16Offset == offset + 1)
        #expect(selection.ranges["a"] == NSRange(location: offset - 1, length: 2))
      } else {
        #expect(selection.anchor.utf16Offset == offset)
        #expect(selection.head.utf16Offset == offset)
        #expect(selection.isEmpty)
      }
    }
  }

  @Test func `bidirectional text uses logical UTF 16 order`() throws {
    let text = "abאבcd"
    let document = try document([.surface(key: "a", text: text)])
    let selection = try #require(document.project(anchor: endpoint("a", 5), head: endpoint("a", 1)))
    let range = try #require(selection.ranges["a"])
    #expect(range == NSRange(location: 1, length: 4))
    #expect((text as NSString).substring(with: range) == "bאבc")
  }

  @Test func `barriers clamp in both travel directions`() throws {
    let document = try document([
      .surface(key: "a", text: "abc"), .surface(key: "b", text: "def"), .barrier,
      .surface(key: "c", text: "ghi"), .surface(key: "d", text: "jkl"),
    ])
    let forward = try #require(document.project(anchor: endpoint("a", 1), head: endpoint("d", 2)))
    #expect(forward.head == endpoint("b", 3, .upstream))
    #expect(forward.orderedKeys == ["a", "b"])
    #expect(forward.ranges == ["a": NSRange(location: 1, length: 2), "b": NSRange(location: 0, length: 3)])
    let reverse = try #require(document.project(anchor: endpoint("d", 1), head: endpoint("a", 0)))
    #expect(reverse.head == endpoint("c", 0))
    #expect(reverse.orderedKeys == ["c", "d"])
    #expect(reverse.ranges == ["c": NSRange(location: 0, length: 3), "d": NSRange(location: 0, length: 1)])
    let atBarrier = try #require(document.project(anchor: endpoint("b", 3), head: endpoint("c", 2)))
    #expect(atBarrier.isEmpty)
    #expect(atBarrier.head == endpoint("b", 3, .upstream))
  }

  @Test func `adjacent barriers stop at the first boundary`() throws {
    let document = try document([
      .barrier, .surface(key: "a", text: "abc"), .barrier, .barrier, .surface(key: "b", text: "def"), .barrier,
    ])
    let forward = try #require(document.project(anchor: endpoint("a", 1), head: endpoint("b", 1)))
    #expect(forward.head == endpoint("a", 3, .upstream))
    let reverse = try #require(document.project(anchor: endpoint("b", 2), head: endpoint("a", 0)))
    #expect(reverse.head == endpoint("b", 0))
  }

  @Test func `duplicate surface keys are rejected`() {
    #expect(Document(entries: [.surface(key: "a", text: "one"), .barrier, .surface(key: "a", text: "two")]) == nil)
    #expect(Document(entries: []) != nil)
    #expect(Document(entries: [.barrier, .barrier]) != nil)
  }

  @Test func `compatibility allows changes outside the endpoint span`() throws {
    let before = try document([
      .surface(key: "outside", text: "old"), .surface(key: "a", text: "abc"), .surface(key: "b", text: "def"),
    ])
    let selection = try #require(before.project(anchor: endpoint("a", 1), head: endpoint("b", 2)))
    let after = try document([
      .surface(key: "new", text: "new"), .barrier, .surface(key: "outside", text: "edited"),
      .surface(key: "a", text: "abc"), .surface(key: "b", text: "def"), .barrier, .surface(key: "tail", text: "new"),
    ])
    #expect(after.isCompatible(with: selection))
  }

  @Test func `compatibility rejects insertion reordering removal and barriers`() throws {
    let a = Document.Entry.surface(key: "a", text: "abc")
    let b = Document.Entry.surface(key: "b", text: "def")
    let c = Document.Entry.surface(key: "c", text: "ghi")
    let before = try document([a, b, c])
    let selection = try #require(before.project(anchor: endpoint("c", 2), head: endpoint("a", 1)))
    let variants: [[Document.Entry]] = [
      [a, c, b], [b, a, c], [a, c], [a, b],
      [a, .surface(key: "inserted", text: ""), b, c], [a, .barrier, b, c],
    ]
    for entries in variants {
      let after = try document(entries)
      #expect(!after.isCompatible(with: selection))
    }
  }

  @Test func `compatibility includes empty surfaces and unselected source suffixes`() throws {
    let a = Document.Entry.surface(key: "a", text: "abc")
    let b = Document.Entry.surface(key: "b", text: "def")
    let before = try document([a, .surface(key: "empty", text: ""), b])
    let selection = try #require(before.project(anchor: endpoint("a", 1), head: endpoint("b", 1)))
    #expect(selection.orderedKeys == ["a", "b"])
    let removedEmpty = try document([a, b])
    #expect(!removedEmpty.isCompatible(with: selection))
    let editedSuffix = try document([a, .surface(key: "empty", text: ""), .surface(key: "b", text: "deF")])
    #expect(!editedSuffix.isCompatible(with: selection))
  }

  @Test func `compatibility compares code units instead of canonical string equality`() throws {
    let first = "A\u{212B}Z"
    let second = "A\u{00C5}Z"
    #expect(first == second)
    #expect(first.utf16.count == second.utf16.count)
    let before = try document([.surface(key: "a", text: first)])
    let after = try document([.surface(key: "a", text: second)])
    let selection = try #require(before.project(anchor: endpoint("a", 0), head: endpoint("a", 1)))
    #expect(!after.isCompatible(with: selection))
  }
}
