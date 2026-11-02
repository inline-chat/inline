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

  @Test("A disclosure row trails its chevron with status and meta")
  func disclosureDecoration() throws {
    let block = RichBlock.disclosure(RichDisclosure(
      summary: Fixtures.text("Ran the tests"),
      children: [Self.p("Output")],
      isExpanded: false,
      status: .failed,
      meta: Fixtures.text("exit 1")
    ))
    let layout = try Self.layout([block])
    guard case let .disclosure(row) = layout.nodes[0].node else { Issue.record("not a disclosure"); return }
    let status = try #require(row.statusFrame)
    let meta = try #require(row.metaFrame)
    #expect(row.status == .failed)
    #expect(status.minX >= row.chevronFrame.maxX)
    #expect(meta.minX >= status.maxX)
    #expect(meta.maxX <= layout.nodes[0].frame.width + 0.5)
  }

  @Test("Quiet statuses draw no glyph, and a childless disclosure has no chevron")
  func disclosureQuietStates() throws {
    let block = RichBlock.disclosure(RichDisclosure(
      summary: Fixtures.text("Read a file"),
      children: [],
      isExpanded: false,
      status: .done
    ))
    let layout = try Self.layout([block])
    guard case let .disclosure(row) = layout.nodes[0].node else { Issue.record("not a disclosure"); return }
    #expect(row.status == nil)
    #expect(row.statusFrame == nil)
    #expect(!row.hasChildren)
    #expect(row.chevronFrame.width == 0)
  }

  @Test("Diffs span the width and give runs of changed lines one background")
  func diffs() throws {
    let lines = ["--- a/file", "+++ b/file", "@@ -1 +1,2 @@", "-old", "+new", "+newer", " same"]
    let block = RichBlock.diff(RichDiff(
      path: Fixtures.text("file"),
      body: Fixtures.text(lines.joined(separator: "\n"), font: Self.mono),
      copyText: lines.joined(separator: "\n")
    ))
    let layout = try Self.layout([block])
    #expect(layout.nodes.count == 1)
    #expect(layout.size.width == 300)
    guard case let .diff(diff) = layout.nodes[0].node else { Issue.record("not a diff"); return }
    #expect(diff.bands.map(\.isAddition) == [false, true])
    #expect(diff.bands[1].frame.height > diff.bands[0].frame.height)
    #expect(diff.contentWidth >= 300)
    #expect(layout.nodes[0].frame.height > diff.headerHeight)
  }

  @Test("A diff with no body is just its header")
  func diffHeaderOnly() throws {
    let layout = try Self.layout([.diff(RichDiff(path: Fixtures.text("image.png")))])
    guard case let .diff(diff) = layout.nodes[0].node else { Issue.record("not a diff"); return }
    #expect(diff.bands.isEmpty)
    #expect(layout.nodes[0].frame.height == diff.headerHeight)
  }

  @Test("Steps put status markers in a column before their text")
  func steps() throws {
    let layout = try Self.layout([.steps(RichSteps(steps: [
      .init(text: Fixtures.text("Fix the bug"), status: .done),
      .init(text: Fixtures.text("Run the tests"), detail: Fixtures.text("Running"), status: .failed),
    ]))])
    #expect(layout.nodes.count == 5)
    guard case .statusMarker(.done) = layout.nodes[0].node, case .statusMarker(.failed) = layout.nodes[2].node else {
      Issue.record("markers missing")
      return
    }
    #expect(layout.nodes[0].frame.minX == layout.nodes[2].frame.minX)
    #expect(layout.nodes[1].frame.minX >= layout.nodes[0].frame.maxX)
    #expect(layout.nodes[4].frame.minY >= layout.nodes[3].frame.maxY)
    #expect(layout.trailingLine == nil)
  }

  @Test("Fields put labels in a column and align their values")
  func fields() throws {
    let layout = try Self.layout([.fields(RichFields(rows: [
      .init(label: Fixtures.text("Command"), value: Fixtures.text("cargo test")),
      .init(label: Fixtures.text("Folder"), value: Fixtures.text("/repo")),
    ]))])
    #expect(layout.nodes.count == 4)
    #expect(layout.nodes[0].frame.minX == layout.nodes[2].frame.minX)
    #expect(layout.nodes[1].frame.minX == layout.nodes[3].frame.minX)
    #expect(layout.nodes[1].frame.minX >= layout.nodes[0].frame.maxX)
    #expect(layout.nodes[2].frame.minY >= max(layout.nodes[0].frame.maxY, layout.nodes[1].frame.maxY))
  }

  @Test("Callouts span the width and hold their title and children")
  func callouts() throws {
    let layout = try Self.layout([.callout(RichCallout(
      tone: .warning,
      title: Fixtures.text("Careful"),
      children: [Self.p("This deletes the build folder")]
    ))])
    #expect(layout.size.width == 300)
    #expect(layout.nodes.count == 3)
    guard case let .callout(callout) = layout.nodes[0].node else { Issue.record("not a callout"); return }
    #expect(callout.tone == .warning)
    let box = layout.nodes[0].frame
    #expect(layout.nodes[1].frame.minX >= callout.iconFrame.maxX)
    #expect(layout.nodes[2].frame.minY >= layout.nodes[1].frame.maxY)
    #expect(layout.nodes[2].frame.maxY < box.maxY)
    #expect(abs(layout.size.height - box.maxY) < 0.5)
  }

  @Test("Groups stack their children with no node of their own")
  func groups() throws {
    let layout = try Self.layout([.group([Self.p("One"), Self.p("Two")])])
    #expect(layout.nodes.map(\.path) == [RichPath([0, 0]), RichPath([0, 1])])
    #expect(layout.trailingLine == nil)
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
