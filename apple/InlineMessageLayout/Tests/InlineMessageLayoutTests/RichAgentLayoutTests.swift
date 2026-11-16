import CoreGraphics
import Foundation
import Testing
@testable import InlineMessageLayout

private func t(_ string: String, size: CGFloat = 17) -> MessageText { Fixtures.text(string, font: Fixtures.font(size)) }
private func p(_ string: String) -> RichBlock { .text(t(string), role: .paragraph) }
private func button(_ title: String, _ id: String, style: RichButton.Style = .standard) -> RichButton {
  RichButton(title: t(title, size: 15), tap: .action(id: id), style: style)
}

@Suite("Rich agent layout")
struct RichAgentLayoutTests {

  static func layout(_ blocks: [RichBlock], width: CGFloat = 300) throws -> RichLayout {
    try #require(RichLayoutPlanner.layout(blocks, maximumWidth: width, grid: Fixtures.grid))
  }

  static func card(_ placed: RichLayout.Placed) -> RichLayout.Card? {
    if case let .card(card) = placed.node { card } else { nil }
  }

  static func parts(_ card: RichLayout.Card, where match: (RichLayout.Card.Part.Kind) -> Bool) -> [RichLayout.Card.Part] {
    card.parts.filter { match($0.kind) }
  }

  static func isText(_ kind: RichLayout.Card.Part.Kind) -> Bool { if case .text = kind { true } else { false } }
  static func isButton(_ kind: RichLayout.Card.Part.Kind) -> Bool { if case .button = kind { true } else { false } }
  static func isChip(_ kind: RichLayout.Card.Part.Kind) -> Bool { if case .chip = kind { true } else { false } }
  static func isStatus(_ kind: RichLayout.Card.Part.Kind) -> Bool {
    if case .symbol(.status) = kind { true } else { false }
  }

  /// Every part sits inside its node, on the pixel grid.
  static func expectInside(_ layout: RichLayout, sourceLocation: SourceLocation = #_sourceLocation) {
    for placed in layout.nodes {
      #expect(placed.frame.maxX <= layout.size.width + 0.01, sourceLocation: sourceLocation)
      #expect(placed.frame.maxY <= layout.size.height + 0.01, sourceLocation: sourceLocation)
      guard let card = card(placed) else { continue }
      for part in card.parts {
        if case .row = part.kind { continue }
        let bounds = CGRect(origin: .zero, size: placed.frame.size).insetBy(dx: -0.01, dy: -0.01)
        #expect(bounds.contains(part.frame), "part \(part.kind) \(part.frame) outside \(placed.frame.size)", sourceLocation: sourceLocation)
        #expect(Fixtures.grid.isAligned(part.frame), sourceLocation: sourceLocation)
      }
    }
  }


  // MARK: Steps

  @Test("A top-level task list is a card with a marker before each step")
  func steps() throws {
    let steps = RichSteps(items: [
      .init(text: t("Read the spec"), status: .done),
      .init(text: t("Write the planner, which takes a while and wraps onto a second line"), detail: t("Planner", size: 14), status: .running),
      .init(text: t("Ship"), status: nil),
    ])
    let layout = try Self.layout([.steps(steps)])
    let card = try #require(Self.card(layout.nodes[0]))
    #expect(card.style == .taskList)
    let markers = Self.parts(card, where: Self.isStatus)
    let texts = Self.parts(card, where: Self.isText)
    #expect(markers.count == 3)
    #expect(texts.count == 4)
    // Markers share a column at the card's leading inset, before their text.
    #expect(Set(markers.map(\.frame.minX)).count == 1)
    #expect(abs(markers[0].frame.minX - RichLayoutMetrics().stepsCardHorizontalInset) < 0.5)
    #expect(markers[0].frame.maxX <= texts[0].frame.minX)
    // Pending steps without a status draw a pending marker.
    if case let .symbol(.status(status)) = markers[2].kind { #expect(status == .pending) } else { Issue.record("no marker") }
    // The task list spans the content width.
    #expect(layout.size.width == 300)
    Self.expectInside(layout)
  }

  @Test("Nested steps are a plain list, and right-to-left steps put markers on the right")
  func nestedAndRightToLeftSteps() throws {
    let nested = RichBlock.quote(children: [.steps(RichSteps(items: [.init(text: t("One"), status: .done)]))], isRightToLeft: false)
    let layout = try Self.layout([nested])
    let card = try #require(layout.nodes.compactMap(Self.card).first)
    #expect(card.style == .plain)

    let rtl = try Self.layout([.steps(RichSteps(items: [.init(text: t("سلام دنیا"), status: .done)], isRightToLeft: true))])
    let rtlCard = try #require(Self.card(rtl.nodes[0]))
    let marker = try #require(Self.parts(rtlCard, where: Self.isStatus).first)
    let text = try #require(Self.parts(rtlCard, where: Self.isText).first)
    #expect(marker.frame.minX >= text.frame.maxX)
  }

  // MARK: Fields, meter, callout, diff

  @Test("Fields hug their content in two columns")
  func fields() throws {
    let fields = RichFields(rows: [.init(label: t("Command"), value: t("ls -la")), .init(label: t("Folder"), value: t("~/dev"))])
    let layout = try Self.layout([.fields(fields)])
    let card = try #require(Self.card(layout.nodes[0]))
    let texts = Self.parts(card, where: Self.isText)
    #expect(texts.count == 4)
    #expect(abs(texts[1].frame.minX - texts[3].frame.minX) < 0.5, "values share a column")
    #expect(layout.size.width < 300)
    Self.expectInside(layout)
  }

  @Test("A meter's bar spans the width under its label")
  func meter() throws {
    let layout = try Self.layout([.meter(RichMeter(label: t("Context"), meta: t("62%", size: 14), fraction: 0.62, tone: .warning))])
    let card = try #require(Self.card(layout.nodes[0]))
    let bar = try #require(card.parts.first { if case .bar = $0.kind { true } else { false } })
    #expect(bar.frame.width == 300)
    #expect(bar.frame.minY > 0)
    Self.expectInside(layout)
  }

  @Test("A callout encloses its title and children")
  func callout() throws {
    let callout = RichCallout(tone: .warning, symbol: "exclamationmark.triangle.fill", title: t("Heads up"), children: [p("Something to know about")])
    let layout = try Self.layout([.callout(callout)])
    #expect(layout.nodes.count == 2)
    let decoration = layout.nodes[0]
    let child = layout.nodes[1]
    #expect(decoration.frame.contains(child.frame))
    let card = try #require(Self.card(decoration))
    #expect(card.hasChildren)
    let title = try #require(Self.parts(card, where: Self.isText).first)
    #expect(child.frame.minY - decoration.frame.minY > title.frame.maxY)
    Self.expectInside(layout)
  }

  @Test("A diff has a header and a body as wide as its longest line")
  func diff() throws {
    let body = Fixtures.text("@@ -1,2 +1,2 @@\n-let a = 1\n+let a = 2 // and a very long trailing comment that won't fit\n context", font: RichLayoutTests.mono)
    let diff = RichDiff(symbol: "pencil.line", path: t("Sources/App/Main.swift"), counts: t("+1 −1", size: 12), body: body, footer: nil)
    let layout = try Self.layout([.diff(diff)])
    guard case let .diff(node) = layout.nodes[0].node else { Issue.record("not a diff"); return }
    #expect(node.body?.lineCount == 4)
    #expect(node.contentWidth > 300)
    #expect(node.pathFrame.maxX <= node.countsFrame.minX)
    #expect(layout.nodes[0].frame.height > node.headerHeight + (node.body?.size.height ?? 0))
  }

  // MARK: Plan proposal

  static func plan(lines: Int, expanded: Bool, decided: Bool = false) -> RichBlock {
    let body = (1 ... lines).map { "Step \($0) of the plan" }
    return .planProposal(RichPlanProposal(
      symbol: "list.bullet.clipboard",
      title: t("Plan"),
      state: RichChip(text: t("Awaiting approval", size: 12), tone: .accent),
      children: [.list(RichList(items: body.map { .init(marker: t("•"), children: [p($0)]) }))],
      collapsedHeight: 120,
      isExpanded: expanded,
      toggle: RichToggle(label: t("Show full plan", size: 14), tap: .toggle(RichPath([0]), isExpanded: !expanded)),
      buttons: decided ? [] : [button("Approve", "approve", style: .primary), button("Keep planning", "keep")],
      decision: decided ? RichStatusLine(symbol: .named("checkmark.circle.fill", tone: .success), text: t("Approved by Mo", size: 14)) : nil
    ))
  }

  @Test("A collapsed plan keeps a task list inside it whole, not squashed")
  func planCollapseKeepsLeafCards() throws {
    let steps = RichSteps(items: (1 ... 12).map { .init(text: t("Task \($0) in the plan"), status: .pending) })
    let block = RichBlock.planProposal(RichPlanProposal(
      symbol: "list.bullet.clipboard",
      title: t("Plan"),
      state: nil,
      children: [p("Intro"), .steps(steps), p("After")],
      collapsedHeight: 120,
      isExpanded: false,
      toggle: RichToggle(label: t("Show full plan", size: 14), tap: .toggle(RichPath([0]), isExpanded: true)),
      buttons: [button("Approve", "approve", style: .primary)],
      decision: nil
    ))
    let layout = try Self.layout([block])
    // Kept cards that aren't containers keep their planned height, so their parts fit.
    for placed in layout.nodes.dropFirst() {
      guard let card = Self.card(placed), !card.hasChildren else { continue }
      #expect(placed.frame.height > 1, "leaf card squashed to \(placed.frame.height)")
      for part in card.parts where part.frame.maxY > placed.frame.height + 0.5 {
        Issue.record("part \(part.kind) at \(part.frame) outside a card of height \(placed.frame.height)")
      }
    }
    // Nothing below the plan overlaps its kept children.
    let plan = layout.nodes[0].frame
    for placed in layout.nodes.dropFirst() {
      #expect(placed.frame.maxY <= plan.maxY + 0.5)
    }
  }

  @Test("A long plan collapses past its height with a toggle, and expands in full")
  func planCollapse() throws {
    let collapsed = try Self.layout([Self.plan(lines: 20, expanded: false)])
    let expanded = try Self.layout([Self.plan(lines: 20, expanded: true)])
    #expect(collapsed.size.height < expanded.size.height)
    let collapsedCard = try #require(Self.card(collapsed.nodes[0]))
    let rows = collapsedCard.parts.filter { if case .row = $0.kind { true } else { false } }
    #expect(rows.count == 1, "the toggle row")
    // No child reaches past the collapsed height under the header.
    let top = collapsed.nodes[0].frame.minY
    let header = try #require(Self.parts(collapsedCard, where: Self.isText).first)
    for child in collapsed.nodes.dropFirst() {
      #expect(child.frame.maxY <= top + header.frame.maxY + RichLayoutMetrics().cardSectionSpacing + 120 + 0.5)
    }
    #expect(collapsed.nodes.count < expanded.nodes.count)
    // Buttons share one row, side by side.
    let buttons = Self.parts(collapsedCard, where: Self.isButton)
    #expect(buttons.count == 2)
    #expect(buttons[0].frame.minY == buttons[1].frame.minY)
    #expect(buttons[0].frame.maxX < buttons[1].frame.minX)
    #expect(buttons[0].tap == .action(id: "approve"))
    Self.expectInside(collapsed)
    Self.expectInside(expanded)
  }

  @Test("A short plan has no toggle; a decided plan shows its decision instead of buttons")
  func shortAndDecidedPlan() throws {
    let short = try Self.layout([Self.plan(lines: 2, expanded: false)])
    let card = try #require(Self.card(short.nodes[0]))
    #expect(!card.parts.contains { if case .row = $0.kind { true } else { false } })
    let decided = try Self.layout([Self.plan(lines: 2, expanded: false, decided: true)])
    let decidedCard = try #require(Self.card(decided.nodes[0]))
    #expect(Self.parts(decidedCard, where: Self.isButton).isEmpty)
    #expect(Self.parts(decidedCard, where: Self.isText).contains { if case let .text(text) = $0.kind { text.text.string == "Approved by Mo" } else { false } })
  }

  // MARK: Approval

  @Test("An approval boxes its command and hides its children until expanded")
  func approval() throws {
    func approval(_ expanded: Bool) -> RichBlock {
      .approval(RichApproval(
        symbol: "terminal",
        title: t("Run a command"),
        state: nil,
        command: Fixtures.text("rm -rf build && swift test --parallel", font: RichLayoutTests.mono),
        details: [t("~/dev/inline", size: 13), t("Clean build before the tests", size: 14)],
        children: [p("diff goes here")],
        isExpanded: expanded,
        toggle: RichToggle(label: t("Show details", size: 14), tap: .toggle(RichPath([0]), isExpanded: !expanded)),
        buttons: [button("Approve", "yes", style: .primary), button("Deny", "no", style: .destructive)],
        decision: nil
      ))
    }
    let closed = try Self.layout([approval(false)])
    let open = try Self.layout([approval(true)])
    #expect(closed.nodes.count == 1)
    #expect(open.nodes.count == 2)
    let card = try #require(Self.card(closed.nodes[0]))
    let box = try #require(card.parts.first { if case .box = $0.kind { true } else { false } })
    let command = try #require(card.parts.first { if case let .text(text) = $0.kind { text.text.string.hasPrefix("rm") } else { false } })
    #expect(box.frame.contains(command.frame))
    let buttons = Self.parts(card, where: Self.isButton)
    #expect(buttons.last.map { $0.frame.maxY < closed.size.height } == true)
    Self.expectInside(closed)
    Self.expectInside(open)
  }

  // MARK: Review

  @Test("Review findings line up after their priority chips; expanded ones show their body")
  func review() throws {
    func review(expanded: Bool) -> RichBlock {
      .review(RichReview(
        symbol: "checklist",
        title: t("Review"),
        verdict: RichChip(text: t("Issues found", size: 12), tone: .critical),
        count: t("2 findings", size: 14),
        summary: nil,
        findings: [
          .init(
            priority: RichChip(text: t("P0", size: 12), tone: .critical),
            title: t("Crash on empty input"),
            location: t("Sources/Parser.swift:12-18", size: 13),
            body: t("When the list is empty the index goes out of range.", size: 14),
            isExpanded: expanded,
            toggle: .toggle(RichPath([0, 0]), isExpanded: !expanded),
            outcome: .named("checkmark.circle.fill", tone: .success),
            button: button("Fix", "fix-0")
          ),
          .init(
            priority: RichChip(text: t("P2", size: 12), tone: .caution),
            title: t("Naming"),
            location: nil,
            body: nil,
            isExpanded: false,
            toggle: nil,
            outcome: nil,
            button: nil
          ),
        ]
      ))
    }
    let closed = try Self.layout([review(expanded: false)])
    let open = try Self.layout([review(expanded: true)])
    #expect(open.size.height > closed.size.height)
    let card = try #require(Self.card(closed.nodes[0]))
    let chips = Self.parts(card, where: Self.isChip)
    #expect(chips.count == 3, "verdict and two priorities")
    let titles = Self.parts(card, where: Self.isText).filter {
      if case let .text(text) = $0.kind { ["Crash on empty input", "Naming"].contains(text.text.string) } else { false }
    }
    #expect(titles.count == 2)
    #expect(abs(titles[0].frame.minX - titles[1].frame.minX) < 0.5)
    #expect(Self.parts(card, where: Self.isButton).first?.tap == .action(id: "fix-0"))
    // Only the finding with a body toggles.
    #expect(card.parts.count(where: { if case .row = $0.kind { true } else { false } }) == 1)
    Self.expectInside(open)
  }

  // MARK: Task suggestion, next step, prompt suggestions

  @Test("A task suggestion clamps its brief to three lines")
  func taskSuggestion() throws {
    let brief = String(repeating: "Refactor the sync engine so that updates apply in order. ", count: 10)
    let task = RichTaskSuggestion(
      symbol: "arrow.triangle.branch",
      title: t("Clean up sync"),
      state: nil,
      brief: t(brief, size: 14),
      buttons: [button("Start", "start", style: .primary), button("Dismiss", "dismiss")],
      status: nil,
      isMuted: false
    )
    let layout = try Self.layout([.taskSuggestion(task)])
    let card = try #require(Self.card(layout.nodes[0]))
    let briefPart = try #require(card.parts.first { if case let .text(text) = $0.kind { text.lineCount > 1 } else { false } })
    guard case let .text(text) = briefPart.kind else { return }
    #expect(text.lineCount == 3)
    #expect(text.text.string.hasSuffix("\u{2026}"))
    #expect(!card.isMuted)
    Self.expectInside(layout)
  }

  @Test("A blocking next step leads with its waiting chip")
  func nextStep() throws {
    let step = RichNextStep(
      recap: t("Done with the planner."),
      question: t("Ship it now?"),
      waiting: RichChip(text: t("Waiting on you", size: 12), tone: .warning, symbol: "hand.raised.fill"),
      buttons: [button("Ship", "ship", style: .primary)]
    )
    let layout = try Self.layout([.nextStep(step)])
    let card = try #require(Self.card(layout.nodes[0]))
    #expect(card.style == .nextStep)
    let chip = try #require(Self.parts(card, where: Self.isChip).first)
    let first = try #require(Self.parts(card, where: Self.isText).first)
    #expect(chip.frame.maxY <= first.frame.minY)
    Self.expectInside(layout)
  }

  @Test("Prompt suggestions wrap into rows of chips")
  func promptSuggestions() throws {
    let prompts = ["Run the tests", "Open a pull request", "Explain the change", "Show the diff"].map {
      RichButton(title: t($0, size: 15), tap: .compose($0), style: .suggestion)
    }
    let layout = try Self.layout([.promptSuggestions(RichPromptSuggestions(prompts: prompts))], width: 260)
    let card = try #require(Self.card(layout.nodes[0]))
    let chips = Self.parts(card, where: Self.isButton)
    #expect(chips.count == 4)
    #expect(Set(chips.map(\.frame.minY)).count > 1, "wraps onto more rows")
    #expect(chips.allSatisfy { $0.frame.maxX <= 260 })
    #expect(chips[0].tap == .compose("Run the tests"))
    Self.expectInside(layout)
  }

  // MARK: Form

  static func form(selected: String?, isRightToLeft: Bool = false, sent: Bool = false) -> RichForm {
    let options = ["oauth", "keys"].map { id in
      RichForm.Option(
        label: t(id == "oauth" ? "OAuth with a long label that wraps onto a second line" : "API keys"),
        detail: id == "keys" ? t("Simpler, less secure", size: 14) : nil,
        isSelected: selected == id,
        tag: id == "oauth" ? RichChip(text: t("Recommended", size: 12), tone: .accent) : nil,
        tap: sent ? nil : .form(.select(formID: "f", fieldID: "auth", optionID: id))
      )
    }
    return RichForm(
      title: t("A few questions"),
      fields: [
        RichForm.Field(
          header: RichChip(text: t("Auth method", size: 12), tone: .neutral),
          label: t("How should people sign in?"),
          detail: nil,
          options: options,
          isMultiple: false,
          answer: nil,
          preview: selected == nil ? nil : t("+--------+\n| Login  |\n+--------+", size: 13)
        ),
        RichForm.Field(
          header: nil,
          label: t("Anything else?"),
          detail: nil,
          options: [],
          isMultiple: false,
          answer: RichForm.Answer(text: t("Your answer"), symbol: "pencil", tap: sent ? nil : .form(.edit(formID: "f", fieldID: "notes"))),
          preview: nil
        ),
      ],
      buttons: sent ? [] : [RichButton(title: t("Submit", size: 15), tap: .form(.submit(formID: "f")), style: .primary)],
      status: sent ? RichStatusLine(symbol: .named("checkmark.circle.fill", tone: .success), text: t("Sent")) : nil,
      note: nil,
      isRightToLeft: isRightToLeft
    )
  }

  @Test("A form shows each question's header, its options as rows that select, and one submit")
  func form() throws {
    let layout = try Self.layout([.form(Self.form(selected: "oauth"))])
    let card = try #require(Self.card(layout.nodes[0]))
    let rows = card.parts.filter { if case .row = $0.kind { true } else { false } }
    #expect(rows.map(\.tap) == [
      .form(.select(formID: "f", fieldID: "auth", optionID: "oauth")),
      .form(.select(formID: "f", fieldID: "auth", optionID: "keys")),
      .form(.edit(formID: "f", fieldID: "notes")),
    ])
    #expect(rows[0].frame.maxY <= rows[1].frame.minY, "option rows don't overlap")
    let chips = Self.parts(card, where: Self.isChip)
    #expect(chips.count == 2, "the header and the recommended tag")
    #expect(chips[0].frame.maxY <= rows[0].frame.minY, "the header sits above the options")
    let marks = card.parts.compactMap { part -> String? in
      if case let .symbol(.named(name, _)) = part.kind { name } else { nil }
    }
    #expect(marks.contains("largecircle.fill.circle"))
    #expect(marks.contains("circle"))
    let boxes = card.parts.filter { if case .box = $0.kind { true } else { false } }
    #expect(boxes.count == 2, "the preview and the typed answer")
    let submit = try #require(Self.parts(card, where: Self.isButton).last)
    #expect(submit.tap == .form(.submit(formID: "f")))
    #expect(boxes.allSatisfy { $0.frame.maxY <= submit.frame.minY })
    Self.expectInside(layout)
  }

  @Test("A sent form has no taps and a status instead of its submit")
  func sentForm() throws {
    let layout = try Self.layout([.form(Self.form(selected: "keys", sent: true))])
    let card = try #require(Self.card(layout.nodes[0]))
    #expect(card.parts.allSatisfy { $0.tap == nil })
    #expect(Self.parts(card, where: Self.isButton).isEmpty)
    Self.expectInside(layout)
  }

  @Test("A right-to-left form puts marks on the right and keeps previews left to right")
  func rightToLeftForm() throws {
    let layout = try Self.layout([.form(Self.form(selected: "oauth", isRightToLeft: true))])
    let card = try #require(Self.card(layout.nodes[0]))
    let width = layout.nodes[0].frame.width
    let mark = try #require(card.parts.first { part in
      if case .symbol(.named("largecircle.fill.circle", _)) = part.kind { true } else { false }
    })
    #expect(mark.frame.midX > width / 2)
    let box = try #require(card.parts.first { if case .box = $0.kind { true } else { false } })
    let preview = try #require(card.parts.first { $0.frame.minY > box.frame.minY && $0.frame.maxY < box.frame.maxY && Self.isText($0.kind) })
    #expect(preview.frame.minX < width / 2, "the preview stays on the left")
    Self.expectInside(layout)
  }

  @Test("Too many questions refuse the form")
  func formLimit() {
    var form = Self.form(selected: nil)
    form.fields = Array(repeating: form.fields[1], count: RichForm.maximumFields + 1)
    #expect(RichLayoutPlanner.layout([.form(form)], maximumWidth: 300, grid: Fixtures.grid) == nil)
  }

  // MARK: Fallback

  /// What the host builds for a message whose third block it can't draw (a kind newer than the
  /// build, or a malformed one): that block becomes a paragraph of its fallback text, and every
  /// other block keeps its own layout.
  @Test("A block drawn as fallback text leaves every other block rich")
  func fallbackKeepsOtherBlocksRich() throws {
    let blocks: [RichBlock] = [
      .text(t("Heading", size: 20), role: .heading(level: 2)),
      .steps(RichSteps(items: [.init(text: t("One"), status: .done), .init(text: t("Two"), status: .running)])),
      // The block this build can't draw, as its fallback paragraph.
      p("A future block's fallback text"),
      .list(RichList(items: [.init(marker: t("•"), children: [p("Item")])])),
      Self.plan(lines: 2, expanded: false),
      .promptSuggestions(RichPromptSuggestions(prompts: [RichButton(title: t("Go"), tap: .compose("Go"), style: .suggestion)])),
    ]
    let layout = try Self.layout(blocks)
    let roots = Dictionary(grouping: layout.nodes, by: { $0.path.components.first ?? -1 })
    #expect(roots.keys.sorted() == [0, 1, 2, 3, 4, 5])
    #expect(roots[1]?.contains { Self.card($0)?.style == .taskList } == true)
    #expect(roots[2]?.count == 1)
    if case let .text(text, role)? = roots[2]?.first?.node {
      #expect(role == .paragraph)
      #expect(text.text.string == "A future block's fallback text")
    } else {
      Issue.record("fallback is not a paragraph")
    }
    #expect(roots[3]?.contains { if case .marker = $0.node { true } else { false } } == true)
    #expect(roots[4]?.contains { Self.card($0)?.style == .plan } == true)
    #expect(roots[5]?.contains { Self.card($0) != nil } == true)
    // Blocks stack in order without overlapping.
    let bottoms = (0 ... 5).map { index in roots[index]!.map(\.frame.maxY).max()! }
    let tops = (0 ... 5).map { index in roots[index]!.map(\.frame.minY).min()! }
    for index in 1 ... 5 { #expect(tops[index] >= bottoms[index - 1]) }
    Self.expectInside(layout)
  }

  @Test("Streaming reveals a card once its text is reached")
  func streamingCards() throws {
    let blocks: [RichBlock] = [p("Intro"), .steps(RichSteps(items: [.init(text: t("One"), status: .pending)]))]
    let sources: [RichPath: Range<Int>] = [RichPath([0]): 0 ..< 5, RichPath([1]): 6 ..< 9]
    let layout = try #require(RichLayoutPlanner.layout(blocks, maximumWidth: 300, grid: Fixtures.grid, sources: sources))
    let early = try #require(layout.revealing(3, grid: Fixtures.grid))
    #expect(early.nodes.count == 1)
    let later = layout.revealing(7, grid: Fixtures.grid)
    #expect(later == nil || later?.nodes.count == 2)
  }
}
