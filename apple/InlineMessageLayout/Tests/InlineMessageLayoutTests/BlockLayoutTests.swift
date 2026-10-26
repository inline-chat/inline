import CoreGraphics
import Testing
@testable import InlineMessageLayout

@Suite("Blocks")
struct BlockLayoutTests {
  typealias Block = MessageLayoutInput.Block

  static func input(
    _ text: String,
    blocks: [Block],
    outgoing: Bool = true,
    reactions: [MessageLayoutInput.Reaction] = []
  ) -> MessageLayoutInput {
    var input = Fixtures.message(text, outgoing: outgoing, reactions: reactions)
    input.blocks = blocks
    return input
  }

  static let photo = Block(id: "media", position: .aboveText, width: .fixed(240), height: 180, isEdgeToEdge: true)

  @Test("A photo with no caption is the bubble, with the time over its corner")
  func photoOnly() throws {
    let layout = MessageLayoutPlanner.layout(Self.input("", blocks: [Self.photo]))
    let media = try #require(layout.frame(.block("media")))
    let time = try #require(layout.frame(.time))
    #expect(layout.timePlacement == .overlay)
    #expect(media == layout.bubble.body)
    #expect(media.size == CGSize(width: 240, height: 180))
    #expect(media.contains(time))
    #expect(abs(media.maxX - time.maxX - 6) < 0.01 && abs(media.maxY - time.maxY - 6) < 0.01)
    #expect(layout.edgeToEdgeBlocks == ["media"])
  }

  @Test("A caption wraps to the photo's width under it")
  func photoWithCaption() throws {
    let caption = "A long caption that is wider than the photo, so it has to wrap onto more lines below it."
    let layout = MessageLayoutPlanner.layout(Self.input(caption, blocks: [Self.photo]))
    let media = try #require(layout.frame(.block("media")))
    let text = try #require(layout.frame(.text))
    #expect(abs(layout.bubble.body.width - 240) < 0.01)
    #expect(media.minY == layout.bubble.body.minY)
    #expect(text.minY >= media.maxY + 8 - 0.01)
    #expect(text.maxX <= media.maxX - 12 + 0.51)
    #expect((layout.text?.lineCount ?? 0) > 1)
    #expect(layout.timePlacement != .overlay)
  }

  @Test("A wide photo shrinks to the lane and keeps its aspect")
  func photoScalesDown() throws {
    let wide = Block(id: "media", position: .aboveText, width: .fixed(1_000), height: 500, isEdgeToEdge: true)
    let layout = MessageLayoutPlanner.layout(Self.input("", blocks: [wide]))
    let media = try #require(layout.frame(.block("media")))
    #expect(media.width < 400)
    #expect(abs(media.height - media.width / 2) <= 0.5)
  }

  @Test("A quoted reply widens a short message and stretches to the bubble")
  func reply() throws {
    let reply = Block(id: "reply", position: .aboveText, width: .flexible(preferred: 180, minimum: 60), height: 40)
    let layout = MessageLayoutPlanner.layout(Self.input("ok", blocks: [reply]))
    let quote = try #require(layout.frame(.block("reply")))
    let text = try #require(layout.frame(.text))
    #expect(quote.width == 180)
    #expect(abs(layout.bubble.body.width - (180 + 24)) < 0.01)
    #expect(quote.minY == layout.bubble.body.minY + 8)
    #expect(text.minY == quote.maxY + 6)
    // A short line still takes the inline time.
    #expect(layout.timePlacement == .inline)
  }

  @Test("A file with no caption takes the time beside its bottom edge")
  func documentOnly() throws {
    let document = Block(id: "document", position: .aboveText, width: .fixed(220), height: 44)
    let layout = MessageLayoutPlanner.layout(Self.input("", blocks: [document]))
    let file = try #require(layout.frame(.block("document")))
    let time = try #require(layout.frame(.time))
    #expect(layout.text == nil)
    #expect(layout.timePlacement == .inline)
    #expect(abs(time.maxY - file.maxY) < 0.51)
    #expect(time.minX >= file.maxX + 6 - 0.01)
    #expect(abs(layout.bubble.body.maxY - file.maxY - 8) < 0.51)
  }

  @Test("A file too wide to share its row puts the time below it")
  func wideDocument() throws {
    let document = Block(id: "document", position: .aboveText, width: .fixed(300), height: 44)
    let layout = MessageLayoutPlanner.layout(Self.input("", blocks: [document]))
    let file = try #require(layout.frame(.block("document")))
    let time = try #require(layout.frame(.time))
    #expect(layout.timePlacement == .below)
    #expect(time.minY >= file.maxY + 6 - 0.01)
  }

  @Test("A link preview under the text moves the time below it")
  func previewBelow() throws {
    let preview = Block(id: "preview", position: .belowText, width: .flexible(preferred: 260, minimum: 160), height: 120)
    let layout = MessageLayoutPlanner.layout(Self.input("https://inline.chat", blocks: [preview]))
    let card = try #require(layout.frame(.block("preview")))
    let text = try #require(layout.frame(.text))
    let time = try #require(layout.frame(.time))
    #expect(card.minY == text.maxY + 6)
    #expect(layout.timePlacement == .below)
    #expect(time.minY >= card.maxY)
  }

  @Test("Reactions on a captionless photo go under it, inside the padding")
  func photoWithReactions() throws {
    let layout = MessageLayoutPlanner.layout(Self.input("", blocks: [Self.photo], reactions: [Fixtures.reaction]))
    let media = try #require(layout.frame(.block("media")))
    let pill = try #require(layout.frame(.reaction(Fixtures.reaction.id)))
    #expect(layout.timePlacement == .reactionsRow)
    #expect(pill.minY >= media.maxY + 8 - 0.01)
    #expect(pill.minX == media.minX + 12)
  }

  @Test("Blocks read in order around the text")
  func readingOrder() {
    let forward = Block(id: "forward", position: .aboveText, width: .fixed(120), height: 16)
    let preview = Block(id: "preview", position: .belowText, width: .flexible(preferred: 200, minimum: 160), height: 80)
    let layout = MessageLayoutPlanner.layout(Self.input("hello", blocks: [forward, preview]))
    #expect(layout.accessibilityOrder.prefix(3) == [.block("forward"), .text, .block("preview")])
  }
}

extension BlockLayoutTests {
  @Test("Buttons sit under the bubble on its side and extend the row")
  func buttonsUnderBubble() throws {
    let buttons = Block(id: "buttons", position: .belowBubble, width: .flexible(preferred: 400, minimum: 100), height: 76)
    for outgoing in [false, true] {
      let layout = MessageLayoutPlanner.layout(Self.input("Pick one", blocks: [buttons], outgoing: outgoing))
      let frame = try #require(layout.frame(.block("buttons")))
      let body = layout.bubble.body
      #expect(abs(frame.minY - (body.maxY + 4)) < 0.51)
      #expect(abs(frame.width - body.width) < 0.51)
      #expect(abs(frame.minX - body.minX) < 0.51)
      #expect(abs(layout.size.height - frame.maxY) < 0.51)
      // The short text keeps its compact bubble; buttons don't widen it.
      #expect(body.width < 200)
    }
  }
}
