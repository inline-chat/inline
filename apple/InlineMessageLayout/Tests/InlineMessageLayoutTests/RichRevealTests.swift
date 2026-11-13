import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import InlineMessageLayout

@Suite("Streaming rich reveal")
struct RichRevealTests {
  static let intro = "First paragraph of a streamed answer that wraps across the bubble, "
    + "then keeps going for a while so it takes a few lines."
  static let code = "let answer = 42\nprint(answer)"
  static let itemOne = "Item one"
  static let itemTwo = "Item two, a little longer"

  /// The flat text and the block tree slicing it: a paragraph, a code block, and a list.
  struct Message {
    var text: String
    var blocks: [RichBlock]
    var sources: [RichPath: Range<Int>]
  }

  static func message() -> Message {
    var text = ""
    var sources: [RichPath: Range<Int>] = [:]
    func add(_ string: String, at path: RichPath) {
      if !text.isEmpty { text += "\n\n" }
      let start = (text as NSString).length
      text += string
      sources[path] = start ..< (text as NSString).length
    }
    add(intro, at: RichPath([0]))
    add(code, at: RichPath([1]))
    add(itemOne, at: RichPath([2, 0, 0]))
    add(itemTwo, at: RichPath([2, 1, 0]))
    let blocks: [RichBlock] = [
      .text(Fixtures.text(intro), role: .paragraph),
      .code(RichCode(text: Fixtures.text(code, font: RichLayoutTests.mono))),
      .list(RichList(items: [
        .init(marker: Fixtures.text("•"), symbol: .bullet, children: [.text(Fixtures.text(itemOne), role: .paragraph)]),
        .init(marker: Fixtures.text("•"), symbol: .bullet, children: [.text(Fixtures.text(itemTwo), role: .paragraph)]),
      ])),
    ]
    return Message(text: text, blocks: blocks, sources: sources)
  }

  static func input(_ message: Message, revealed: Int?, sources: Bool = true) -> MessageLayoutInput {
    var input = Fixtures.message("unused", footer: revealed == nil ? .visible : .reserved)
    input.body = .rich(message.blocks)
    input.richSources = sources ? message.sources : nil
    input.revealedLength = revealed
    return input
  }

  @Test("A streaming rich body grows by lines and nodes and ends at the full layout")
  func growsByLineAndNode() throws {
    let message = Self.message()
    let length = (message.text as NSString).length
    let full = MessageLayoutPlanner.layout(Self.input(message, revealed: nil))
    let fullRich = try #require(full.rich)

    var heights: [CGFloat] = []
    var nodeCounts: [Int] = []
    for revealed in stride(from: 1, to: length, by: 2) {
      let layout = MessageLayoutPlanner.layout(Self.input(message, revealed: revealed))
      let rich = try #require(layout.rich)
      heights.append(layout.size.height)
      nodeCounts.append(rich.nodes.count)
      #expect(rich.size.height <= fullRich.size.height)
      #expect(rich.size.width == fullRich.size.width)
      // Nodes whose text starts past the count are not shown.
      for node in rich.nodes {
        if let range = node.sourceRange { #expect(range.lowerBound < revealed) }
      }
    }
    #expect(heights == heights.sorted(), "the row shrank while revealing: \(heights)")
    #expect(nodeCounts == nodeCounts.sorted())
    #expect(nodeCounts.first == 1)

    let done = MessageLayoutPlanner.layout(Self.input(message, revealed: length))
    #expect(done.revealedLength == nil)
    #expect(done.rich?.size == fullRich.size)
    #expect(done.rich?.nodes.count == fullRich.nodes.count)
    #expect(done.rich?.revealLimit == nil)
  }

  @Test("The frontier paragraph is sized to its frontier line and carries its local count")
  func frontierLine() throws {
    let message = Self.message()
    let full = try #require(MessageLayoutPlanner.layout(Self.input(message, revealed: nil)).rich)
    guard case let .text(intro, _) = full.nodes[0].node else {
      Issue.record("first node is not text")
      return
    }
    #expect(intro.lineCount >= 2)
    let revealed = 5
    let layout = MessageLayoutPlanner.layout(Self.input(message, revealed: revealed))
    let rich = try #require(layout.rich)
    #expect(layout.revealedLength == revealed)
    #expect(rich.nodes.count == 1)
    #expect(rich.nodes[0].revealedLength == revealed)
    #expect(abs(rich.size.height - intro.lines[0].frame.maxY) < 0.5)
    // Stale once the frontier enters the second line.
    #expect(rich.revealLimit == NSMaxRange(intro.lines[0].range))
    #expect(rich.trailingLine != nil)

    let limit = try #require(rich.revealLimit)
    let before = try #require(MessageLayoutPlanner.layout(Self.input(message, revealed: limit - 1)).rich)
    let after = try #require(MessageLayoutPlanner.layout(Self.input(message, revealed: limit)).rich)
    #expect(before.size.height == rich.size.height)
    #expect(after.size.height > rich.size.height)
  }

  @Test("Code shows whole once reached; markers show with their item")
  func wholeNodes() throws {
    let message = Self.message()
    let codeStart = try #require(message.sources[RichPath([1])]).lowerBound
    let atCode = try #require(MessageLayoutPlanner.layout(Self.input(message, revealed: codeStart + 1)).rich)
    #expect(atCode.nodes.count == 2)
    guard case .code = atCode.nodes[1].node else {
      Issue.record("second node is not the code block")
      return
    }
    #expect(atCode.nodes[1].revealedLength == nil)
    #expect(abs(atCode.size.height - atCode.nodes[1].frame.maxY) < 0.5)
    // The code is not a root paragraph, so the time drops below it.
    #expect(atCode.trailingLine == nil)

    let itemStart = try #require(message.sources[RichPath([2, 0, 0])]).lowerBound
    let beforeItem = try #require(MessageLayoutPlanner.layout(Self.input(message, revealed: itemStart)).rich)
    #expect(!beforeItem.nodes.contains { if case .marker = $0.node { true } else { false } })
    #expect(beforeItem.revealLimit == itemStart + 1)
    let atItem = try #require(MessageLayoutPlanner.layout(Self.input(message, revealed: itemStart + 1)).rich)
    let markers = atItem.nodes.filter { if case .marker = $0.node { true } else { false } }
    #expect(markers.count == 1)
    if case let .marker(_, symbol) = markers.first?.node {
      #expect(symbol == .bullet)
    }
  }

  @Test("Without sources, or with sources out of order, the rich body shows whole")
  func fallsBack() throws {
    let message = Self.message()
    let unmapped = MessageLayoutPlanner.layout(Self.input(message, revealed: 3, sources: false))
    #expect(unmapped.revealedLength == nil)
    #expect(unmapped.rich?.nodes.count == MessageLayoutPlanner.layout(Self.input(message, revealed: nil)).rich?.nodes.count)

    var shuffled = message
    shuffled.sources[RichPath([0])] = 200 ..< 210
    let unordered = MessageLayoutPlanner.layout(Self.input(shuffled, revealed: 3))
    #expect(unordered.revealedLength == nil)
  }

  @Test("A quote's rail ends under its revealed children")
  func quoteRail() throws {
    let first = "Quoted line one"
    let second = "Quoted line two"
    let blocks: [RichBlock] = [.quote(children: [
      .text(Fixtures.text(first), role: .paragraph),
      .text(Fixtures.text(second), role: .paragraph),
    ], isRightToLeft: false)]
    let sources: [RichPath: Range<Int>] = [
      RichPath([0, 0]): 0 ..< 15,
      RichPath([0, 1]): 16 ..< 31,
    ]
    let full = try #require(RichLayoutPlanner.layout(blocks, maximumWidth: 300, grid: Fixtures.grid, sources: sources))
    let partial = try #require(full.revealing(3, grid: Fixtures.grid))
    #expect(partial.nodes.count == 2)
    let rail = partial.nodes[0].frame
    #expect(rail.height < full.nodes[0].frame.height)
    #expect(abs(rail.maxY - (partial.nodes[1].frame.maxY + RichLayoutMetrics().quoteVerticalInset)) < 0.5)
    #expect(abs(partial.size.height - rail.maxY) < 0.5)
  }

  @Test("A long disclosure summary ends in an ellipsis within its row")
  func disclosureEllipsis() throws {
    let summary = Fixtures.text("Searched the repository for every place the renderer measures text and compared them")
    let blocks: [RichBlock] = [.disclosure(RichDisclosure(summary: summary, children: [], isExpanded: false))]
    let layout = try #require(RichLayoutPlanner.layout(blocks, maximumWidth: 200, grid: Fixtures.grid))
    guard case let .disclosure(disclosure) = layout.nodes[0].node else {
      Issue.record("not a disclosure")
      return
    }
    #expect(disclosure.summary.lineCount == 1)
    #expect(disclosure.summary.text.string.hasSuffix("\u{2026}"))
    #expect(disclosure.summary.size.width <= disclosure.titleFrame.width + 0.5)
    #expect(disclosure.fullSummary == summary)
    #expect(disclosure.chevronFrame.maxX <= layout.size.width + 0.5)

    let short = Fixtures.text("Read files")
    let fits = try #require(RichLayoutPlanner.layout(
      [.disclosure(RichDisclosure(summary: short, children: [], isExpanded: false))],
      maximumWidth: 200,
      grid: Fixtures.grid
    ))
    if case let .disclosure(row) = fits.nodes[0].node {
      #expect(row.summary.text.string == "Read files")
    }
  }
}
