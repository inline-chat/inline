import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import InlineMessageLayout

@Suite("Rich layout")
struct RichLayoutTests {
  static var mono: CTFont { CTFontCreateUIFontForLanguage(.userFixedPitch, 14, nil)! }

  static func p(_ string: String) -> RichBlock { .text(Fixtures.text(string), role: .paragraph) }
  static func h(_ string: String, _ level: Int) -> RichBlock {
    .text(Fixtures.text(string, font: Fixtures.font(20)), role: .heading(level: level))
  }
  static func list(_ items: [[RichBlock]], ordered: Bool = false, rtl: Bool = false) -> RichBlock {
    .list(RichList(
      items: items.enumerated().map { index, children in
        .init(marker: Fixtures.text(ordered ? "\(index + 1)." : "•"), children: children)
      },
      isRightToLeft: rtl
    ))
  }
  static func code(_ string: String, language: String? = "Swift") -> RichBlock {
    let lines = string.components(separatedBy: "\n").count
    return .code(RichCode(
      text: Fixtures.text(string, font: mono),
      lineNumbers: language == nil ? nil : Fixtures.text((1 ... lines).map(String.init).joined(separator: "\n"), font: mono),
      languageLabel: language.map { Fixtures.text($0, font: Fixtures.font(11)) }
    ))
  }

  static func layout(_ blocks: [RichBlock], width: CGFloat = 300) throws -> RichLayout {
    try #require(RichLayoutPlanner.layout(blocks, maximumWidth: width, grid: Fixtures.grid))
  }

  @Test("Paragraphs stack with block spacing and fit their widest line")
  func paragraphs() throws {
    let layout = try Self.layout([Self.p("Short"), Self.p("A second paragraph that is a little longer")])
    #expect(layout.nodes.count == 2)
    let first = layout.nodes[0].frame
    let second = layout.nodes[1].frame
    #expect(abs(second.minY - first.maxY - 8) < 0.5)
    #expect(abs(layout.size.width - second.width) <= 1)
    #expect(layout.size.width < 300)
    #expect(layout.trailingLine != nil)
  }

  @Test("A heading after a paragraph gets extra space")
  func headings() throws {
    let layout = try Self.layout([Self.p("Intro"), Self.h("Section", 2), Self.p("Body")])
    let gap = layout.nodes[1].frame.minY - layout.nodes[0].frame.maxY
    #expect(abs(gap - (8 + 7)) < 0.5)
  }

  @Test("List markers sit in a column before their items")
  func lists() throws {
    let layout = try Self.layout([Self.list([[Self.p("One")], [Self.p("Two, which is longer")], [Self.p("Three")]], ordered: true)])
    let markers = layout.nodes.filter { if case .marker = $0.node { true } else { false } }
    let texts = layout.nodes.filter { if case .text = $0.node { true } else { false } }
    #expect(markers.count == 3 && texts.count == 3)
    let column = texts.map(\.frame.minX)
    #expect(Set(column).count == 1, "item text starts at one x: \(column)")
    for (marker, text) in zip(markers, texts) {
      #expect(marker.frame.maxX <= text.frame.minX + 0.01)
      #expect(abs(marker.frame.minY - text.frame.minY) < 0.5)
    }
  }

  @Test("Right-to-left lists put markers on the right")
  func rightToLeftLists() throws {
    let layout = try Self.layout([Self.list([[Self.p("سلام دنیا")], [Self.p("خداحافظ")]], rtl: true)], width: 300)
    let marker = try #require(layout.nodes.first { if case .marker = $0.node { true } else { false } })
    let text = try #require(layout.nodes.first { if case .text = $0.node { true } else { false } })
    #expect(marker.frame.minX >= text.frame.maxX - 0.01)
  }

  @Test("Quotes inset their children and their rail spans them")
  func quotes() throws {
    let layout = try Self.layout([.quote(children: [Self.p("Quoted words"), Self.p("More")], isRightToLeft: false)])
    let rail = try #require(layout.nodes.first)
    guard case .quote = rail.node else { Issue.record("first node is not the quote"); return }
    for child in layout.nodes.dropFirst() {
      #expect(rail.frame.contains(child.frame), "\(child.frame) outside \(rail.frame)")
      #expect(child.frame.minX >= rail.frame.minX + 9 - 0.01)
    }
    #expect(abs(rail.frame.maxX - layout.size.width) < 0.5)
  }

  @Test("Code spans the width, never wraps, and scrolls when a line is long")
  func code() throws {
    let long = String(repeating: "let value = compute(input) ", count: 6)
    let layout = try Self.layout([Self.p("Look:"), Self.code("short\n\(long)")])
    let node = try #require(layout.nodes.last)
    guard case let .code(code) = node.node else { Issue.record("not code"); return }
    #expect(layout.size.width == 300)
    #expect(node.frame.width == 300)
    #expect(code.text.lineCount == 2)
    #expect(code.contentWidth > 300)
    #expect(code.languageLabel != nil && code.lineNumbers != nil)
    #expect(code.textOrigin.x > code.lineNumbersOrigin.x + (code.lineNumbers?.size.width ?? 0))
    #expect(layout.trailingLine == nil, "time can't follow a code block")
  }

  @Test("Tables share width by need, and scroll when columns can't fit")
  func tables() throws {
    let narrow = RichTable(rows: [
      [Fixtures.text("Name"), Fixtures.text("Value")],
      [Fixtures.text("a"), Fixtures.text("1")],
    ])
    let small = try Self.layout([.table(narrow)])
    guard case let .table(table) = small.nodes[0].node else { Issue.record("not a table"); return }
    #expect(abs(table.contentSize.width - 300) < 0.5)
    #expect(table.cells.count == 4)
    for cell in table.cells {
      #expect(cell.frame.contains(cell.textFrame.insetBy(dx: 0.5, dy: 0.5)), "text outside cell \(cell.row),\(cell.column)")
    }
    let wide = RichTable(rows: [(0 ..< 10).map { Fixtures.text("Column\($0)Header") }, (0 ..< 10).map { Fixtures.text("value \($0)") }])
    let scrolling = try Self.layout([.table(wide)])
    guard case let .table(big) = scrolling.nodes[0].node else { Issue.record("not a table"); return }
    #expect(big.contentSize.width > 300)
    #expect(scrolling.nodes[0].frame.width == 300)
  }

  @Test("Disclosures show children only when expanded")
  func disclosures() throws {
    func disclosure(_ expanded: Bool) -> RichBlock {
      .disclosure(RichDisclosure(summary: Fixtures.text("Worked for 2m"), children: [Self.p("Read 3 files")], isExpanded: expanded, isInProgress: true))
    }
    let closed = try Self.layout([disclosure(false)])
    let open = try Self.layout([disclosure(true)])
    #expect(closed.nodes.count == 1)
    #expect(open.nodes.count == 2)
    #expect(open.size.height > closed.size.height)
    guard case let .disclosure(summary) = closed.nodes[0].node else { Issue.record("not a disclosure"); return }
    #expect(summary.chevronFrame.minX >= summary.titleFrame.maxX)
  }

  @Test("Images keep their aspect inside the width and the height cap")
  func images() throws {
    let layout = try Self.layout([.image(RichImage(id: "a", size: CGSize(width: 1_200, height: 800))), .image(RichImage(id: "b", size: nil))])
    let wide = layout.nodes[0].frame
    #expect(wide.width <= 300 && abs(wide.height - wide.width * 800 / 1_200) <= 1)
    #expect(layout.nodes[1].frame.size == CGSize(width: 240, height: 180))
  }

  @Test("A message with a rich body puts its time after the closing paragraph")
  func richMessage() throws {
    var input = Fixtures.message("unused")
    input.body = .rich([Self.h("Plan", 1), Self.list([[Self.p("First")], [Self.p("Second")]]), Self.p("Done.")])
    let layout = MessageLayoutPlanner.layout(input)
    let rich = try #require(layout.rich)
    let frame = try #require(layout.frame(.text))
    #expect(frame.size == rich.size)
    #expect(layout.timePlacement == .inline)
    let time = try #require(layout.frame(.time))
    #expect(time.minY >= frame.maxY - 30 && time.maxY <= frame.maxY + 8)
    var coded = input
    coded.body = .rich([Self.p("Run this:"), Self.code("bun test")])
    let codedLayout = MessageLayoutPlanner.layout(coded)
    #expect(codedLayout.timePlacement == .below)
  }

  // MARK: - Corpus

  @Test("Hundreds of random rich trees keep every geometric rule")
  func corpus() throws {
    var random = SeededRandom(seed: 0x41C4)
    var failures: [String] = []
    var checked = 0
    for index in 0 ..< 400 {
      let blocks = (0 ..< (1 + random.next(5))).map { _ in Self.randomBlock(&random, depth: 0) }
      let width = CGFloat([220, 280, 320, 360][random.next(4)])
      guard let layout = RichLayoutPlanner.layout(blocks, maximumWidth: width, grid: Fixtures.grid) else {
        failures.append("#\(index): nil layout")
        continue
      }
      checked += 1
      let again = RichLayoutPlanner.layout(blocks, maximumWidth: width, grid: Fixtures.grid)
      if again?.nodes.map(\.frame) != layout.nodes.map(\.frame) { failures.append("#\(index): not deterministic") }
      if layout.size.width > width + 0.01 { failures.append("#\(index): wider than \(width)") }
      let bounds = CGRect(origin: .zero, size: layout.size).insetBy(dx: -0.51, dy: -0.51)
      for node in layout.nodes {
        if !Fixtures.grid.isAligned(node.frame) { failures.append("#\(index) \(node.path): off grid \(node.frame)") }
        if !bounds.contains(node.frame) { failures.append("#\(index) \(node.path): \(node.frame) outside \(layout.size)") }
      }
      // Leaf content never overlaps other leaf content.
      let leaves = layout.nodes.filter { if case .quote = $0.node { false } else { true } }
      for (a, first) in leaves.enumerated() {
        for second in leaves[(a + 1)...] where first.frame.insetBy(dx: 0.26, dy: 0.26).intersects(second.frame) {
          failures.append("#\(index): \(first.path) \(first.frame) overlaps \(second.path) \(second.frame)")
        }
      }
    }
    #expect(checked >= 390)
    #expect(failures.isEmpty, "\(failures.count) violations:\n\(failures.prefix(30).joined(separator: "\n"))")
  }

  static func randomBlock(_ random: inout SeededRandom, depth: Int) -> RichBlock {
    let words = ["alpha", "beta", "gamma", "سلام", "delta", "a-much-longer-token", "epsilon", "z"]
    func sentence() -> String {
      (0 ..< (1 + random.next(12))).map { _ in words[random.next(words.count)] }.joined(separator: " ")
    }
    let choice = depth > 2 ? random.next(3) : random.next(9)
    switch choice {
    case 0, 1: return p(sentence())
    case 2: return h(sentence(), 1 + random.next(4))
    case 3: return list((0 ..< (1 + random.next(4))).map { _ in [randomBlock(&random, depth: depth + 1)] }, ordered: random.bool())
    case 4: return .quote(children: [randomBlock(&random, depth: depth + 1)], isRightToLeft: random.next(5) == 0)
    case 5: return code((0 ..< (1 + random.next(5))).map { _ in sentence() }.joined(separator: "\n"), language: random.bool() ? "Swift" : nil)
    case 6:
      let columns = 1 + random.next(4)
      return .table(RichTable(rows: (0 ..< (1 + random.next(4))).map { _ in (0 ..< columns).map { _ in Fixtures.text(sentence()) } }))
    case 7: return random.bool() ? .separator : .image(RichImage(id: "i", size: CGSize(width: 100 + random.next(1_000), height: 100 + random.next(1_000))))
    default:
      return .disclosure(RichDisclosure(summary: Fixtures.text(sentence()), children: [randomBlock(&random, depth: depth + 1)], isExpanded: random.bool()))
    }
  }
}
