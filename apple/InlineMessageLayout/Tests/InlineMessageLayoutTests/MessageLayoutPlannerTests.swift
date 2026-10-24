import CoreGraphics
import Testing
@testable import InlineMessageLayout

@Suite("Message layout planner")
struct MessageLayoutPlannerTests {
  let metrics = MessageLayoutMetrics()

  @Test("Gold standard: adding a reaction narrows the bubble, drops the time and puts the reaction bottom-left")
  func goldStandard() throws {
    // Wide enough that the inline time costs real width.
    let string = "Sounds good, see you tomorrow"
    let before = MessageLayoutPlanner.layout(Fixtures.message(string))
    let after = MessageLayoutPlanner.layout(Fixtures.message(string, reactions: [Fixtures.reaction]))

    #expect(before.timePlacement == .inline)
    #expect(before.text?.lineCount == 1)
    #expect(after.timePlacement == .reactionsRow)
    #expect(after.text?.lineCount == 1)

    #expect(after.bubble.frame.width < before.bubble.frame.width)
    #expect(after.bubble.frame.height > before.bubble.frame.height)

    let text = try #require(after.frame(.text))
    let time = try #require(after.frame(.time))
    let reaction = try #require(after.frame(.reaction("👍")))
    #expect(time.minY >= text.maxY)
    #expect(reaction.minY >= text.maxY + metrics.reactionsTopSpacing - 0.5)
    #expect(reaction.minX == text.minX)
    #expect(abs(reaction.midY - time.midY) <= 1)
    #expect(abs(time.maxX - (after.bubble.body.maxX - metrics.bubbleInsets.trailing)) <= 0.5)

    let transition = MessageLayoutTransition(from: before, to: after)
    #expect(transition.changes[.reaction("👍")] == .inserted(reaction))
    #expect(transition.changes[.time] == .moved(from: try #require(before.frame(.time)), to: time))
    #expect(transition.changes[.bubble] != nil)
    #expect(transition.changesHeight)
    #expect(MessageLayoutTransition(from: after, to: after).isEmpty)
  }

  @Test("The time stays inline after a short last line and moves below a long one")
  func timePlacement() throws {
    let short = MessageLayoutPlanner.layout(Fixtures.message(
      "This message has enough words to wrap onto a second line. Yes"
    ))
    #expect((short.text?.lineCount ?? 0) > 1)
    #expect(short.timePlacement == .inline)

    // Grow the last line until the time no longer fits beside it.
    var string = "This message has enough words to wrap onto a second line."
    var layout = MessageLayoutPlanner.layout(Fixtures.message(string))
    while layout.timePlacement == .inline {
      string += " more"
      layout = MessageLayoutPlanner.layout(Fixtures.message(string))
    }
    #expect(layout.timePlacement == .below)
    let text = try #require(layout.frame(.text))
    let time = try #require(layout.frame(.time))
    #expect(abs(time.minY - (text.maxY + metrics.timeRowSpacing)) <= 0.5)
    #expect(layout.bubble.body.maxY - time.maxY == metrics.bubbleInsets.bottom)
  }

  @Test("Inline time shares the last line's baseline")
  func inlineBaseline() throws {
    let layout = MessageLayoutPlanner.layout(Fixtures.message("Hi"))
    let text = try #require(layout.frame(.text))
    let time = try #require(layout.frame(.time))
    let bodyBaseline = text.minY + (layout.text?.lastBaseline ?? 0)
    let timeBaseline = time.minY + layout.time.firstBaseline
    #expect(abs(bodyBaseline - timeBaseline) <= 0.5)
    #expect(time.maxY <= layout.bubble.body.maxY - metrics.bubbleInsets.bottom + 0.5)
  }

  @Test("Bubbles respect the width cap and line up across a group")
  func widthAndAlignment() throws {
    let long = String(repeating: "Wide message ", count: 30)
    let rowWidth: CGFloat = 390
    let lane = rowWidth - metrics.rowLeadingInset - metrics.rowTrailingInset
    let layout = MessageLayoutPlanner.layout(Fixtures.message(long, rowWidth: rowWidth))
    #expect(layout.bubble.body.width <= lane * metrics.maximumBubbleWidthFraction - metrics.tailWidth + 0.5)

    let tailed = MessageLayoutPlanner.layout(Fixtures.message("Last", tail: .leading))
    let grouped = MessageLayoutPlanner.layout(Fixtures.message("Earlier", tail: BubbleTailSide.none))
    #expect(tailed.bubble.body.minX == grouped.bubble.body.minX)
    #expect(tailed.bubble.frame.minX == tailed.bubble.body.minX - metrics.tailWidth)
    #expect(grouped.bubble.frame == grouped.bubble.body)

    let outgoing = MessageLayoutPlanner.layout(Fixtures.message("Mine", outgoing: true))
    #expect(outgoing.bubble.frame.maxX == rowWidth - metrics.rowTrailingInset)
    #expect(outgoing.bubble.body.maxX == rowWidth - metrics.rowTrailingInset - metrics.tailWidth)
  }

  @Test("Right-to-left interfaces mirror the row")
  func mirroring() throws {
    let ltr = MessageLayoutPlanner.layout(Fixtures.message("Hello"))
    let rtl = MessageLayoutPlanner.layout(Fixtures.message("Hello", direction: .rightToLeft))
    #expect(rtl.bubble.frame.maxX == ltr.size.width - ltr.bubble.frame.minX)
    #expect(rtl.bubble.frame.width == ltr.bubble.frame.width)
    let time = try #require(rtl.frame(.time))
    let text = try #require(rtl.frame(.text))
    #expect(time.maxX <= text.minX + 0.5) // trailing is now on the left
  }

  @Test("A multi-line right-to-left message puts the time below; a single line keeps it inline")
  func rightToLeftText() {
    let single = MessageLayoutPlanner.layout(Fixtures.message("سلام"))
    #expect(single.timePlacement == .inline)
    #expect(single.text?.lines.first?.frame.minX == 0)

    let multi = MessageLayoutPlanner.layout(Fixtures.message(
      String(repeating: "این یک پیام طولانی است که باید شکسته شود ", count: 3)
    ))
    #expect((multi.text?.lineCount ?? 0) > 1)
    #expect(multi.timePlacement == .below)
  }

  @Test("Large emoji have no bubble")
  func emoji() {
    let layout = MessageLayoutPlanner.layout(Fixtures.message("😀", emoji: true))
    #expect(!layout.bubble.isVisible)
    #expect(layout.frame(.bubble) == nil)
    #expect(layout.bubble.tail == .none)
    #expect(layout.timePlacement == .below)
  }

  @Test("A reserved footer keeps the same geometry and only hides the time")
  func reservedFooter() {
    let visible = MessageLayoutPlanner.layout(Fixtures.message("Streaming"))
    let reserved = MessageLayoutPlanner.layout(Fixtures.message("Streaming", footer: .reserved))
    #expect(visible.frames == reserved.frames)
    #expect(reserved.hiddenNodes == [.time])
    let reveal = MessageLayoutTransition(from: reserved, to: visible)
    #expect(reveal.changes.isEmpty)
    #expect(reveal.shown == [.time])
  }

  @Test("Many reactions wrap, and the time moves below a full last row")
  func reactionWrapping() throws {
    let reactions = (0 ..< 9).map { MessageLayoutInput.Reaction(id: "r\($0)", size: CGSize(width: 52, height: 26)) }
    let layout = MessageLayoutPlanner.layout(Fixtures.message("Party", reactions: reactions))
    let frames = try reactions.map { try #require(layout.frame(.reaction($0.id))) }
    #expect(Set(frames.map(\.minY)).count > 1)
    let content = layout.bubble.body.inset(by: metrics.bubbleInsets)
    #expect(frames.allSatisfy { content.insetBy(dx: -0.5, dy: -0.5).contains($0) })
    #expect(layout.reactionOrder == reactions.map(\.id))
    if layout.timePlacement == .below {
      #expect(try #require(layout.frame(.time)).minY >= frames.map(\.maxY).max()!)
    }
  }

  @Test("The avatar sits at the bubble's bottom in its own column")
  func avatar() throws {
    let layout = MessageLayoutPlanner.layout(Fixtures.message("With avatar", avatar: .visible))
    let avatar = try #require(layout.frame(.avatar))
    #expect(avatar.maxY == layout.bubble.body.maxY)
    #expect(avatar.minX == metrics.rowLeadingInset)
    #expect(layout.bubble.frame.minX >= avatar.maxX + metrics.avatarSpacing - 0.5)
    let reserved = MessageLayoutPlanner.layout(Fixtures.message("With avatar", avatar: .reserved))
    #expect(reserved.frame(.avatar) == nil)
    #expect(reserved.bubble.frame == layout.bubble.frame)
  }

  @Test("Every frame is finite, pixel-aligned and deterministic", arguments: [false, true])
  func invariants(outgoing: Bool) {
    let strings = ["Hi", "سلام", String(repeating: "Wrap me please ", count: 12), "😀😀", "A\n\nB\n"]
    for rowWidth: CGFloat in [320, 375, 390, 430, 768] {
      for string in strings {
        for reactions in [[], [Fixtures.reaction]] {
          let input = Fixtures.message(string, rowWidth: rowWidth, outgoing: outgoing, reactions: reactions)
          let layout = MessageLayoutPlanner.layout(input)
          let again = MessageLayoutPlanner.layout(input)
          #expect(layout.frames == again.frames)
          #expect(layout.size.height == again.size.height)
          for (node, frame) in layout.frames {
            #expect(Fixtures.isFinite(frame), "\(node) \(frame)")
            #expect(Fixtures.grid.isAligned(frame), "\(node) \(frame) not on the pixel grid")
            #expect(frame.minX >= 0 && frame.maxX <= rowWidth + 0.01, "\(node) outside the row")
            if node != .bubble, node != .avatar, node != .name {
              #expect(layout.bubble.body.insetBy(dx: -0.01, dy: -0.01).contains(frame), "\(node) outside the bubble")
            }
          }
          #expect(layout.size.height >= layout.bubble.frame.maxY)
          #expect(layout.bubble.body.height >= metrics.cornerRadius * 2)
        }
      }
    }
  }

  @Test("Cached and uncached plans match")
  func cachedPlans() {
    let cache = TextLayoutCache()
    let input = Fixtures.message(String(repeating: "Cache me ", count: 10), reactions: [Fixtures.reaction])
    let cached = MessageLayoutPlanner.layout(input, cache: cache)
    let fresh = MessageLayoutPlanner.layout(input)
    #expect(cached.frames == fresh.frames)
    #expect(MessageLayoutPlanner.layout(input, cache: cache).frames == cached.frames)
  }
}

private extension CGRect {
  func inset(by insets: MessageLayoutMetrics.Insets) -> CGRect {
    CGRect(
      x: minX + insets.leading,
      y: minY + insets.top,
      width: width - insets.horizontal,
      height: height - insets.vertical
    )
  }
}
