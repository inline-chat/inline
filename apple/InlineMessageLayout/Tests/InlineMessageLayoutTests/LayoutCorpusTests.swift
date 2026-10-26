import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import InlineMessageLayout

/// A seeded lab of hundreds of message shapes. Every case must satisfy the geometric rules the
/// view relies on; failures are collected so one run shows every broken shape at once.
@Suite("Layout corpus")
struct LayoutCorpusTests {
  static let strings = [
    "ok",
    "Sounds good, see you tomorrow",
    "On my way, but the train is running a little late. I'll message again when I'm close.",
    "First paragraph.\n\nSecond paragraph after a blank line.\nAnd a third line.",
    "سلام! این پیام فارسی است و باید از راست به چپ نمایش داده شود.",
    "שלום, זו הודעה בעברית עם כמה מילים.",
    "Mixed English then فارسی then English again in one line",
    "فارسی first, then English words after it",
    "Emoji in text 😀🎉👍 should wrap like letters 🙌🏽",
    "https://inline.chat/very/long/path/that/has/no/spaces/to/break/at/all/and/keeps/going/on",
    "Supercalifragilisticexpialidocious-and-another-very-long-hyphenated-word",
    "这是一条中文消息，用来测试换行和宽度。",
    "e\u{301}e\u{301}e\u{301} combining marks, Zalgo-ish: Z\u{0351}\u{0352}a\u{0300}l\u{0301}g\u{0302}o",
    "Trailing newline\n",
    "\nLeading newline",
    "1\n2\n3\n4\n5\n6\n7\n8",
    ".",
    String(repeating: "Long message that keeps going. ", count: 20),
  ]
  static let rowWidths: [CGFloat] = [320, 360, 375, 390, 414, 430, 744, 1024]
  static let bodySizes: [CGFloat] = [14, 17, 19, 23, 28]

  struct Case: CustomStringConvertible {
    var input: MessageLayoutInput
    var label: String
    var description: String { label }
  }

  static func cases(count: Int, seed: UInt64) -> [Case] {
    var random = SeededRandom(seed: seed)
    return (0 ..< count).map { index in
      let string = strings[random.next(strings.count)]
      let rowWidth = rowWidths[random.next(rowWidths.count)]
      let bodySize = bodySizes[random.next(bodySizes.count)]
      let outgoing = random.bool()
      let reactionCount = random.next(4) == 0 ? random.next(9) + 1 : (random.bool() ? 1 : 0)
      let reactions = (0 ..< reactionCount).map { reaction in
        MessageLayoutInput.Reaction(
          id: "r\(reaction)",
          size: CGSize(width: CGFloat(40 + random.next(50)), height: CGFloat(26 + random.next(7)))
        )
      }
      let acknowledgement = random.next(5) == 0 ? CGSize(width: CGFloat(28 + random.next(30)), height: 16) : nil
      let avatar: MessageLayoutInput.Avatar = outgoing ? .none : [.none, .reserved, .visible][random.next(3)]
      let name = !outgoing && random.next(3) == 0 ? Fixtures.text("Ava Lin", font: Fixtures.font(13)) : nil
      let tail: BubbleTailSide = random.bool() ? (outgoing ? .trailing : .leading) : .none
      let emoji = random.next(12) == 0
      let body = emoji
        ? MessageLayoutInput.Body.emoji(Fixtures.text(["😀", "🎉👍", "🙌🏽🔥😂"][random.next(3)], font: Fixtures.font(70)))
        : .text(Fixtures.text(string, font: Fixtures.font(bodySize)))
      let footer: MessageLayoutInput.Footer.Visibility = random.next(6) == 0 ? .reserved : .visible
      // A third of the bubbles carry blocks: replies, forwards, media, files, voice, previews, buttons.
      var blocks: [MessageLayoutInput.Block] = []
      if !emoji, random.next(3) == 0 {
        if random.next(4) == 0 { blocks.append(.init(id: "forward", position: .aboveText, width: .fixed(CGFloat(60 + random.next(160))), height: 16)) }
        if random.next(3) == 0 { blocks.append(.init(id: "reply", position: .aboveText, width: .flexible(preferred: CGFloat(60 + random.next(220)), minimum: 60), height: 40)) }
        switch random.next(4) {
        case 0: blocks.append(.init(id: "media", position: .aboveText, width: .fixed(CGFloat(120 + random.next(320))), height: CGFloat(80 + random.next(340)), isEdgeToEdge: true))
        case 1: blocks.append(.init(id: "document", position: .aboveText, width: .fixed(CGFloat(180 + random.next(100))), height: 44))
        case 2: blocks.append(.init(id: "voice", position: .aboveText, width: .flexible(preferred: 240, minimum: 120), height: 54))
        default: break
        }
        if random.next(3) == 0 { blocks.append(.init(id: "preview", position: .belowText, width: .flexible(preferred: CGFloat(160 + random.next(200)), minimum: 160), height: CGFloat(50 + random.next(150)))) }
        if random.next(5) == 0 { blocks.append(.init(id: "summary", position: .belowText, width: .flexible(preferred: 200, minimum: 190), height: [36, 52][random.next(2)])) }
        if random.next(5) == 0 { blocks.append(.init(id: "buttons", position: .belowBubble, width: .flexible(preferred: 200, minimum: 100), height: CGFloat(34 + random.next(80)))) }
      }
      // Attachments often come without a caption.
      let caption = !blocks.isEmpty && random.next(3) == 0 ? "" : string
      let content = emoji ? body : .text(Fixtures.text(caption, font: Fixtures.font(bodySize)))
      let input = MessageLayoutInput(
        rowWidth: rowWidth,
        grid: PixelGrid(scale: [2, 3][random.next(2)]),
        isOutgoing: outgoing,
        isFirstInGroup: random.bool(),
        tail: tail,
        avatar: avatar,
        name: name,
        body: content,
        footer: .init(
          time: Fixtures.text("12:34", font: Fixtures.font(bodySize * 11 / 17)),
          statusSize: outgoing ? CGSize(width: bodySize * 11 / 17, height: bodySize * 11 / 17) : nil,
          visibility: footer
        ),
        reactions: reactions,
        blocks: blocks,
        acknowledgementSize: acknowledgement
      )
      let text = emoji ? "emoji" : String(string.prefix(18)).replacingOccurrences(of: "\n", with: "⏎")
      return Case(
        input: input,
        label: "#\(index) blocks=\(blocks.map(\.id)) w=\(Int(rowWidth)) size=\(Int(bodySize)) out=\(outgoing) r=\(reactionCount) ack=\(acknowledgement != nil) name=\(name != nil) avatar=\(avatar) tail=\(tail) \"\(text)\""
      )
    }
  }

  @Test("Hundreds of shapes keep every geometric rule")
  func corpus() {
    var failures: [String] = []
    for testCase in Self.cases(count: 800, seed: 0x1A2B_3C4D) {
      failures += Self.violations(in: testCase.input).map { "\(testCase): \($0)" }
    }
    #expect(failures.isEmpty, "\(failures.count) violations:\n\(failures.prefix(40).joined(separator: "\n"))")
  }

  @Test("Right-to-left rows are exact mirrors of left-to-right rows")
  func mirroring() {
    var failures: [String] = []
    for testCase in Self.cases(count: 200, seed: 0x5EED) {
      var rtl = testCase.input
      rtl.layoutDirection = .rightToLeft
      let a = MessageLayoutPlanner.layout(testCase.input)
      let b = MessageLayoutPlanner.layout(rtl)
      // Multi-line text reads from its own leading edge, so whether the time fits inline depends on
      // the interface direction; only single lines and emoji mirror exactly.
      guard (a.text?.lineCount ?? 0) <= 1 else { continue }
      for (node, frame) in a.frames {
        guard let mirrored = b.frames[node] else {
          failures.append("\(testCase): \(node) missing in RTL")
          continue
        }
        let expected = CGRect(x: testCase.input.rowWidth - frame.maxX, y: frame.minY, width: frame.width, height: frame.height)
        if !close(mirrored, expected, tolerance: 0.01) {
          failures.append("\(testCase): \(node) \(mirrored) != mirror \(expected)")
        }
      }
    }
    #expect(failures.isEmpty, "\(failures.count) violations:\n\(failures.prefix(40).joined(separator: "\n"))")
  }

  @Test("Transitions describe exactly what moved, appeared and left")
  func transitions() {
    var failures: [String] = []
    for testCase in Self.cases(count: 300, seed: 0xF00D) {
      var next = testCase.input
      // Toggle one reaction and the footer, the commonest live updates.
      if next.reactions.isEmpty {
        next.reactions = [.init(id: "new", size: CGSize(width: 44, height: 32))]
      } else {
        next.reactions.removeLast()
      }
      next.footer.visibility = next.footer.visibility == .visible ? .reserved : .visible
      let old = MessageLayoutPlanner.layout(testCase.input)
      let new = MessageLayoutPlanner.layout(next)
      let transition = MessageLayoutTransition(from: old, to: new)
      for (node, frame) in new.frames {
        switch transition.changes[node] {
        case .none where old.frames[node] != frame:
          failures.append("\(testCase): \(node) changed without a change entry")
        case let .moved(from, to)? where from != old.frames[node] || to != frame:
          failures.append("\(testCase): \(node) moved entry is wrong")
        case .inserted? where old.frames[node] != nil:
          failures.append("\(testCase): \(node) marked inserted but existed")
        default:
          break
        }
      }
      for node in old.frames.keys where new.frames[node] == nil {
        if transition.changes[node] != .removed(old.frames[node]!) {
          failures.append("\(testCase): \(node) left without a removal entry")
        }
      }
      if transition.shown.union(transition.hidden) != [.time] {
        failures.append("\(testCase): footer visibility flip not reported")
      }
    }
    #expect(failures.isEmpty, "\(failures.count) violations:\n\(failures.prefix(40).joined(separator: "\n"))")
  }

  // MARK: - Rules

  static func violations(in input: MessageLayoutInput) -> [String] {
    let layout = MessageLayoutPlanner.layout(input)
    var problems: [String] = []
    func fail(_ message: String) { problems.append(message) }

    let again = MessageLayoutPlanner.layout(input)
    if again.frames != layout.frames || again.size != layout.size { fail("not deterministic") }

    let m = input.metrics
    let grid = input.grid
    let body = layout.bubble.body
    let insets = layout.bubble.isVisible ? m.bubbleInsets : m.emojiInsets
    let content = CGRect(
      x: body.minX + insets.leading,
      y: body.minY + insets.top,
      width: body.width - insets.horizontal,
      height: body.height - insets.vertical
    )

    // Every frame is finite, on the pixel grid and inside the row.
    for (node, frame) in layout.frames {
      if !Fixtures.isFinite(frame) { fail("\(node) not finite: \(frame)") }
      if !grid.isAligned(frame) { fail("\(node) off the pixel grid: \(frame)") }
      if frame.minX < -0.01 || frame.maxX > input.rowWidth + 0.01 { fail("\(node) outside the row: \(frame)") }
      if frame.maxY > layout.size.height + 0.01 { fail("\(node) below the row: \(frame)") }
    }

    // Content stays inside the bubble's padding; edge-to-edge media and the time pill over it
    // stay inside the body.
    let edgeNodes = Set(layout.edgeToEdgeBlocks.map(MessageLayoutNode.block))
    let outsideNodes = Set(input.blocks.filter { $0.position == .belowBubble }.map { MessageLayoutNode.block($0.id) })
    for node in outsideNodes {
      guard let frame = layout.frame(node) else { continue }
      if frame.minY < body.maxY + m.belowBubbleSpacing - 0.51 { fail("\(node) \(frame) not under the bubble \(body)") }
      if frame.minX < body.minX - 0.51 || frame.maxX > body.maxX + 0.51 { fail("\(node) \(frame) wider than the bubble \(body)") }
    }
    let overMedia = layout.timePlacement == .overlay && !edgeNodes.isEmpty
    var contentNodes: [(MessageLayoutNode, CGRect)] = []
    for (node, frame) in layout.frames {
      switch node {
      case .bubble, .avatar, .name: continue
      default:
        if outsideNodes.contains(node) { continue }
        contentNodes.append((node, frame))
      }
      let isOnMedia = edgeNodes.contains(node) || overMedia && (node == .time || node == .acknowledgement)
      if !(isOnMedia ? body : content).insetBy(dx: -0.51, dy: -0.51).contains(frame) {
        fail("\(node) \(frame) outside \(isOnMedia ? "body" : "content") \(isOnMedia ? body : content)")
      }
    }
    for id in input.blocks.map(\.id) where layout.bubble.isVisible && layout.frame(.block(id)) == nil {
      fail("block \(id) not placed")
    }

    // Width cap and edge alignment.
    let avatarColumn = input.isOutgoing || input.avatar == .none ? 0 : m.avatarSize + m.avatarSpacing
    let lane = input.rowWidth - m.rowLeadingInset - m.rowTrailingInset - avatarColumn
    if body.width > lane * m.maximumBubbleWidthFraction + 0.51 { fail("body \(body.width) wider than the cap") }
    if layout.bubble.isVisible, body.height < m.cornerRadius * 2 - 0.01 { fail("body shorter than two radii") }
    let edge = input.isOutgoing
      ? abs(body.maxX - (input.rowWidth - m.rowTrailingInset - m.bodyEdgeInset))
      : abs(body.minX - (m.rowLeadingInset + avatarColumn + m.bodyEdgeInset))
    if edge > 0.51 { fail("body not on its lane edge (off by \(edge))") }

    // Fit width: something reaches the content's trailing edge. Media sets its own width.
    let reach = contentNodes.filter { !edgeNodes.contains($0.0) }.map(\.1.maxX).max() ?? content.maxX
    if layout.bubble.isVisible, edgeNodes.isEmpty, abs(reach - content.maxX) > 1.01 {
      fail("bubble wider than its content: reach \(reach) vs \(content.maxX)")
    }

    // Text lines stay inside the text frame and the content width.
    if let text = layout.text, let frame = layout.frame(.text) {
      for line in text.lines {
        let rect = line.frame.offsetBy(dx: frame.minX, dy: frame.minY)
        if rect.maxX > frame.maxX + 0.51 || rect.minX < frame.minX - 0.51 { fail("line \(line.range) outside text frame") }
        if line.width > content.width + 0.51 { fail("line \(line.range) wider than content") }
      }
    }

    // Nothing overlaps, except the emoji time pill, which sits over the emoji on purpose.
    let lineRects: [CGRect] = {
      guard let text = layout.text, let frame = layout.frame(.text) else { return [] }
      return text.lines.filter { $0.width > 0 }.map {
        CGRect(x: frame.minX + $0.frame.minX, y: frame.minY + $0.frame.minY, width: $0.width, height: $0.frame.height)
      }
    }()
    let solids = contentNodes.filter { $0.0 != .text }
    // The time pill over captionless media sits on the media on purpose.
    func overlapsOnPurpose(_ a: MessageLayoutNode, _ b: MessageLayoutNode) -> Bool {
      overMedia && (edgeNodes.contains(a) && [.time, .acknowledgement].contains(b)
        || edgeNodes.contains(b) && [.time, .acknowledgement].contains(a))
    }
    for (index, a) in solids.enumerated() {
      for b in solids[(index + 1)...] where a.1.insetBy(dx: 0.26, dy: 0.26).intersects(b.1) && !overlapsOnPurpose(a.0, b.0) {
        fail("\(a.0) \(a.1) overlaps \(b.0) \(b.1)")
      }
      // Over large emoji, the time and Ack pills sit on the emoji's corner like the current view.
      if layout.timePlacement == .overlay, a.0 == .time || a.0 == .acknowledgement { continue }
      for line in lineRects where a.1.insetBy(dx: 0.26, dy: 0.26).intersects(line) {
        fail("\(a.0) \(a.1) overlaps text line \(line)")
      }
    }

    // Inline time shares the last line's baseline.
    if layout.timePlacement == .inline, let text = layout.text, let textFrame = layout.frame(.text),
       let time = layout.frame(.time), input.acknowledgementSize == nil
    {
      let statusHeight = input.footer.statusSize?.height ?? 0
      let timeTextTop = time.minY + (time.height - layout.time.size.height) / 2
      let timeBaseline = timeTextTop + layout.time.firstBaseline
      let bodyBaseline = textFrame.minY + text.lastBaseline
      if statusHeight <= layout.time.size.height, abs(timeBaseline - bodyBaseline) > 1.01 {
        fail("inline time baseline \(timeBaseline) vs text \(bodyBaseline)")
      }
    }

    // Avatar sits at the bubble's bottom, name above it.
    if let avatar = layout.frame(.avatar), abs(avatar.maxY - body.maxY) > 0.51 { fail("avatar not bottom-aligned") }
    if let name = layout.frame(.name), name.maxY > layout.bubble.frame.minY + 0.51 { fail("name overlaps bubble") }

    // A streaming footer only hides; it never moves anything.
    var visible = input
    visible.footer.visibility = .visible
    if input.footer.visibility == .reserved, MessageLayoutPlanner.layout(visible).frames != layout.frames {
      fail("reserved footer changes geometry")
    }
    return problems
  }
}

/// Deterministic xorshift generator, so a failing case reproduces from its index.
struct SeededRandom {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
  }

  mutating func next(_ upperBound: Int) -> Int {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return Int(state % UInt64(max(1, upperBound)))
  }

  mutating func bool() -> Bool { next(2) == 1 }
}

func close(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
  abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
    && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}
