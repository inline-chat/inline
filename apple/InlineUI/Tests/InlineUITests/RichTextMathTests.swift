import Foundation
import InlineProtocol
import Testing
@testable import TextProcessing

@Suite("Native display math projection")
@MainActor
struct RichTextMathTests {
  private func text(_ source: String, color: PlatformColor = .black) -> NSAttributedString {
    NSAttributedString(string: source, attributes: [.foregroundColor: color])
  }

  @Test("Display ranges traverse containers and reject malformed UTF-16 bounds")
  func displayRanges() {
    func math(_ offset: Int64, _ length: Int64) -> Block {
      Block.with { $0.math = BlockText.with { $0.offset = offset; $0.length = length } }
    }
    let content = BlockContent.with {
      $0.blocks = [
        math(3, 2), math(-1, 2), math(Int64.max, 1), math(1, Int64.max), math(0, 0),
        Block.with { $0.quote = BlockQuote.with { $0.children = [math(6, 1)] } },
        Block.with { $0.disclosure = BlockDisclosure.with { $0.children = [math(8, 2)] } },
      ]
    }
    #expect(RichTextMath.displayRanges(in: content, sourceLength: 10) == [
      NSRange(location: 3, length: 2), NSRange(location: 6, length: 1), NSRange(location: 8, length: 2),
    ])
    let large = BlockContent.with { $0.blocks = Array(repeating: math(0, 1), count: 100) }
    #expect(RichTextMath.displayRanges(in: large, sourceLength: 1).count == RichTextMath.maximumFormulas)
  }

  @Test("Requests preserve literal source and reject broken ranges and oversized inputs")
  func sourceBounds() throws {
    let source = text("😀 e\u{301} + x")
    let range = NSRange(location: 3, length: source.length - 3)
    let request = try #require(RichTextMath.request(text: source, range: range, fontSize: 17))
    #expect(Array(request.tex.utf16) == Array("e\u{301} + x".utf16))
    #expect(request.display)
    for invalid in [NSRange(location: 1, length: 2), NSRange(location: 0, length: 1),
                    NSRange(location: -1, length: 1), NSRange(location: 0, length: Int.max),
                    NSRange(location: source.length, length: 1)] {
      #expect(RichTextMath.request(text: source, range: invalid, fontSize: 17) == nil)
    }
    #expect(RichTextMath.request(text: source, range: range, fontSize: .nan) == nil)
    let tooLong = text(String(repeating: "x", count: 8193))
    #expect(RichTextMath.request(text: tooLong, range: NSRange(location: 0, length: tooLong.length), fontSize: 17) == nil)
    let tooManyBytes = text(String(repeating: "é", count: 5000))
    #expect(RichTextMath.request(text: tooManyBytes, range: NSRange(location: 0, length: tooManyBytes.length), fontSize: 17) == nil)
  }

  @Test("Raster readiness changes layout identity without mutating canonical text or offsets")
  func preparation() async throws {
    let source = text("😀 " + #"\frac{x_{732891}}{y}+\sqrt{z}"# + " tail")
    let range = NSRange(location: 3, length: source.length - 8)
    let canonical = Array(source.string.utf16)
    let before = RichTextMath.snapshot(ranges: [range], text: source, fontSize: 19)
    #expect(before.requests.count == 1)
    #expect(await RichTextMath.prepare(before.requests))
    let ready = RichTextMath.snapshot(ranges: [range], text: source, fontSize: 19)
    let image = try #require(ready.image(for: range))
    #expect(image.width > 0 && image.height > 0)
    #expect(ready.image(for: NSRange(location: range.location + 1, length: range.length)) == nil)
    #expect(Array(source.string.utf16) == canonical)
    #expect(ready.requests == before.requests)
    #expect(!ready.hasPending)
    #expect(before.refreshed().signature == ready.signature)
    if before.image(for: range) == nil { #expect(ready.signature != before.signature) }
    #expect(await RichTextMath.prepare(ready.requests))
    #expect(ready.refreshed().signature == ready.signature)
    #expect(RichTextMath.snapshot(ranges: [range], text: source, fontSize: 19).signature == ready.signature)
    let unsupported = text(#"\unsupportedinlinecommand{q}"#)
    let fallback = RichTextMath.snapshot(ranges: [NSRange(location: 0, length: unsupported.length)], text: unsupported, fontSize: 17)
    #expect(!(await RichTextMath.prepare(fallback.requests)))
    #expect(RichTextMath.snapshot(ranges: [NSRange(location: 0, length: unsupported.length)], text: unsupported, fontSize: 17)
      .image(for: NSRange(location: 0, length: unsupported.length)) == nil)
  }

  @Test("Color and font changes cannot reuse another appearance's pixels")
  func appearance() throws {
    let range = NSRange(location: 0, length: 1)
    let normal = try #require(RichTextMath.request(text: text("x"), range: range, fontSize: 17))
    let larger = try #require(RichTextMath.request(text: text("x"), range: range, fontSize: 24))
    let light = try #require(RichTextMath.request(text: text("x", color: .white), range: range, fontSize: 17))
    #expect(normal != larger)
    #expect(normal != light)
    #expect(normal.color != light.color)
  }
}
