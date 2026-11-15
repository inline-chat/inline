import CoreGraphics
import Testing
@testable import InlineMessageLayout

private func t(_ string: String, size: CGFloat = 17) -> MessageText { Fixtures.text(string, font: Fixtures.font(size)) }
private func p(_ string: String) -> RichBlock { .text(t(string), role: .paragraph) }
private func button(_ title: String, _ id: String) -> RichButton {
  RichButton(title: t(title, size: 15), tap: .action(id: id))
}

@Suite("Rich layout drawn actions")
struct RichLayoutActionsTests {
  private static func plan(_ children: [RichBlock], expanded: Bool) -> RichBlock {
    .planProposal(RichPlanProposal(
      symbol: "list.bullet.clipboard",
      title: t("Plan"),
      state: nil,
      children: children,
      collapsedHeight: 120,
      isExpanded: expanded,
      toggle: RichToggle(label: t("Show full plan", size: 14), tap: .toggle(RichPath([0]), isExpanded: !expanded)),
      buttons: [button("Approve", "approve")],
      decision: nil
    ))
  }

  private static func task(_ id: String) -> RichBlock {
    .taskSuggestion(RichTaskSuggestion(
      symbol: "arrow.triangle.branch",
      title: t("Split off the parser fix"),
      state: nil,
      brief: nil,
      buttons: [button("Start", id)],
      status: nil,
      isMuted: false
    ))
  }

  private static func layout(_ blocks: [RichBlock], metrics: RichLayoutMetrics = .init()) -> RichLayout? {
    RichLayoutPlanner.layout(blocks, maximumWidth: 300, grid: Fixtures.grid, metrics: metrics)
  }

  @Test("A card a collapsed plan cuts off draws none of its actions until the plan expands")
  func collapsedPlanCut() throws {
    let steps = (1 ... 20).map { p("Step \($0) of the plan") }
    let children = steps + [Self.task("start")]
    let owners = ["approve": RichPath([0]), "start": RichPath([0, steps.count])]

    let collapsed = try #require(Self.layout([Self.plan(children, expanded: false)]))
    #expect(collapsed.drawnActions(owners) == ["approve"])

    let expanded = try #require(Self.layout([Self.plan(children, expanded: true)]))
    #expect(expanded.drawnActions(owners) == ["approve", "start"])
  }

  @Test("A card the cut runs through hides the buttons below it")
  func shortenedContainer() throws {
    let approval = RichBlock.approval(RichApproval(
      symbol: "terminal",
      title: t("Run the migration"),
      state: nil,
      command: nil,
      details: [],
      children: (1 ... 12).map { p("Detail line \($0)") },
      isExpanded: true,
      toggle: nil,
      buttons: [button("Allow", "allow")],
      decision: nil
    ))
    let owners = ["approve": RichPath([0]), "allow": RichPath([0, 1])]
    let collapsed = try #require(Self.layout([Self.plan([p("Intro"), approval], expanded: false)]))
    #expect(collapsed.drawnActions(owners) == ["approve"])
    let expanded = try #require(Self.layout([Self.plan([p("Intro"), approval], expanded: true)]))
    #expect(expanded.drawnActions(owners) == ["approve", "allow"])
  }

  @Test("Content past the node cap lays out as nil, so it draws no actions")
  func nodeCap() {
    var metrics = RichLayoutMetrics()
    metrics.maximumNodes = 3
    let blocks = [p("One"), p("Two"), Self.task("start"), p("Four")]
    #expect(Self.layout(blocks, metrics: metrics) == nil)
    #expect(Self.layout(blocks)?.drawnActions(["start": RichPath([2])]) == ["start"])
  }
}
