import Testing
@testable import InlineMacSidebarModel

@Suite("Sidebar activity ordering")
struct SidebarCollectionActivityOrderingTests {
  @Test("a root follows the newest activity in its attached subtree")
  func parentUsesNewestReplyActivity() {
    let ordering = SidebarCollectionActivityOrdering(
      childrenByParentID: ["parent": ["reply"]],
      activityByNodeID: ["parent": 10, "reply": 40, "other": 30],
      stableIDs: ["parent", "reply", "other"]
    )

    #expect(ordering.ordered(["parent", "other"]) == ["parent", "other"])
    #expect(ordering.subtreeActivity(for: "parent") == 40)
  }

  @Test("siblings use their own subtree activity")
  func repliesSortWithinTheirParent() {
    let ordering = SidebarCollectionActivityOrdering(
      childrenByParentID: ["parent": ["older", "newer"]],
      activityByNodeID: ["parent": 1, "older": 10, "newer": 20],
      stableIDs: ["parent", "older", "newer"]
    )

    #expect(ordering.ordered(["older", "newer"]) == ["newer", "older"])
  }

  @Test("equal activity preserves the supplied stable order")
  func stableTieOrder() {
    let ordering = SidebarCollectionActivityOrdering(
      childrenByParentID: [:],
      activityByNodeID: ["first": 10, "second": 10],
      stableIDs: ["second", "first"]
    )

    #expect(ordering.ordered(["first", "second"]) == ["second", "first"])
  }

  @Test("duplicate stable identifiers keep the first coordinate without trapping")
  func duplicateStableIDsAreSafe() {
    let ordering = SidebarCollectionActivityOrdering(
      childrenByParentID: [:],
      activityByNodeID: ["first": 10, "second": 10],
      stableIDs: ["second", "first", "second"]
    )

    #expect(ordering.ordered(["first", "second"]) == ["second", "first"])
  }
}
