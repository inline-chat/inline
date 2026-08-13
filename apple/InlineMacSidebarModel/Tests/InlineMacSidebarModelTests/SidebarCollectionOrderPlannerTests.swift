import InlineMacSidebarModel
import Testing

@Suite("Sidebar collection order planner")
struct SidebarCollectionOrderPlannerTests {
  @Test("plans before, between, and after valid neighbors")
  func plansValidNeighbors() {
    let between: (String?, String?) -> String = { left, right in
      "\(left ?? "start")|\(right ?? "end")"
    }

    #expect(SidebarCollectionOrderPlanner.insertionOrder(
      hasPrevious: false,
      previousOrder: nil,
      hasNext: true,
      nextOrder: "b",
      between: between
    ) == "start|b")
    #expect(SidebarCollectionOrderPlanner.insertionOrder(
      hasPrevious: true,
      previousOrder: "a",
      hasNext: true,
      nextOrder: "b",
      between: between
    ) == "a|b")
    #expect(SidebarCollectionOrderPlanner.insertionOrder(
      hasPrevious: true,
      previousOrder: "a",
      hasNext: false,
      nextOrder: nil,
      between: between
    ) == "a|end")
  }

  @Test("rejects incomplete, duplicate, and reversed neighbor keys")
  func rejectsInvalidNeighbors() {
    let between: (String?, String?) -> String = { _, _ in "unused" }

    #expect(SidebarCollectionOrderPlanner.insertionOrder(
      hasPrevious: true,
      previousOrder: nil,
      hasNext: false,
      nextOrder: nil,
      between: between
    ) == nil)
    #expect(SidebarCollectionOrderPlanner.insertionOrder(
      hasPrevious: false,
      previousOrder: nil,
      hasNext: true,
      nextOrder: nil,
      between: between
    ) == nil)
    #expect(SidebarCollectionOrderPlanner.insertionOrder(
      hasPrevious: true,
      previousOrder: "b",
      hasNext: true,
      nextOrder: "b",
      between: between
    ) == nil)
    #expect(SidebarCollectionOrderPlanner.insertionOrder(
      hasPrevious: true,
      previousOrder: "c",
      hasNext: true,
      nextOrder: "b",
      between: between
    ) == nil)

    #expect(SidebarCollectionOrderPlanner.insertionOrder(
      hasPrevious: false,
      previousOrder: "a",
      hasNext: false,
      nextOrder: nil,
      between: between
    ) == nil)

    #expect(SidebarCollectionOrderPlanner.insertionOrder(
      hasPrevious: false,
      previousOrder: nil,
      hasNext: false,
      nextOrder: "b",
      between: between
    ) == nil)
  }
}
