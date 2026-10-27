import CoreGraphics
import Foundation
import Testing
@testable import InlineMessageLayout

@Suite("Streaming reveal")
struct RevealLayoutTests {
  static let answer = "First line of a streamed answer that wraps across the bubble. "
    + "A second sentence keeps going for a while, until it wraps again onto another line."

  @Test("A streaming body grows a line at a time and ends at the full layout")
  func growsByLine() throws {
    var input = Fixtures.message(Self.answer)
    let full = MessageLayoutPlanner.layout(input)
    let text = try #require(full.text)
    #expect(text.lineCount >= 3)

    var heights: [CGFloat] = []
    for revealed in stride(from: 0, to: text.length, by: 3) {
      input.revealedLength = revealed
      let layout = MessageLayoutPlanner.layout(input)
      heights.append(layout.size.height)
      #expect(layout.revealedLength == revealed)
      let frame = try #require(layout.frame(.text))
      let frontier = try #require(text.lines.first { NSMaxRange($0.range) > revealed })
      #expect(abs(frame.height - frontier.frame.maxY) < 0.01, "body sized past the frontier line at \(revealed)")
    }
    #expect(heights == heights.sorted(), "the row shrank while revealing: \(heights)")
    #expect(Set(heights).count <= text.lineCount, "the row changed height within a line")

    input.revealedLength = text.length
    let done = MessageLayoutPlanner.layout(input)
    #expect(done.revealedLength == nil)
    #expect(done.size == full.size)
    #expect(done.frames == full.frames)
  }

  @Test("The first revealed line sets the bubble width, not the widest line still to come")
  func widthFollowsRevealedLines() throws {
    var input = Fixtures.message("Hi.\n" + Self.answer)
    let full = MessageLayoutPlanner.layout(input)
    input.revealedLength = 2
    let start = MessageLayoutPlanner.layout(input)
    #expect(start.bubble.body.width < full.bubble.body.width)
    #expect(start.size.height < full.size.height)
  }

  @Test("Rich and emoji bodies ignore the reveal")
  func onlyTextReveals() {
    var emoji = Fixtures.message("😀", emoji: true)
    emoji.revealedLength = 0
    #expect(MessageLayoutPlanner.layout(emoji).revealedLength == nil)
    var rich = Fixtures.message("unused")
    rich.body = .rich([.text(Fixtures.text("Streaming rich text"), role: .paragraph)])
    rich.revealedLength = 1
    #expect(MessageLayoutPlanner.layout(rich).revealedLength == nil)
  }
}
