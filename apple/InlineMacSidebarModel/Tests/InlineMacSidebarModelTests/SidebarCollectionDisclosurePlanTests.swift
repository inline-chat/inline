import InlineMacSidebarModel
import Testing

@Suite("Sidebar collection disclosure plan")
struct SidebarCollectionDisclosurePlanTests {
  @Test("section disclosure separates one contiguous lane from its trailing rows")
  func sectionDisclosure() throws {
    let plan = try #require(SidebarCollectionDisclosurePlan(
      expandedIDs: ["pinned", "a", "b", "open", "new-thread"],
      collapsedIDs: ["pinned", "open", "new-thread"],
      ownerID: "pinned"
    ))

    #expect(plan.affectedIDs == ["a", "b"])
    #expect(plan.trailingIDs == ["open", "new-thread"])
  }

  @Test("section disclosure includes its action row in the collapsible block")
  func sectionDisclosureWithActionRow() throws {
    let plan = try #require(SidebarCollectionDisclosurePlan(
      expandedIDs: ["open", "new-thread", "a", "b", "footer"],
      collapsedIDs: ["open", "footer"],
      ownerID: "open"
    ))

    #expect(plan.affectedIDs == ["new-thread", "a", "b"])
    #expect(plan.trailingIDs == ["footer"])
  }

  @Test("nested disclosure uses the same owner and tail contract")
  func nestedDisclosure() throws {
    let plan = try #require(SidebarCollectionDisclosurePlan(
      expandedIDs: ["parent", "reply-a", "reply-b", "sibling"],
      collapsedIDs: ["parent", "sibling"],
      ownerID: "parent"
    ))

    #expect(plan.affectedIDs == ["reply-a", "reply-b"])
    #expect(plan.trailingIDs == ["sibling"])
  }

  @Test("noncontiguous removals are not disclosure")
  func rejectsNoncontiguousRemoval() {
    let plan = SidebarCollectionDisclosurePlan(
      expandedIDs: ["owner", "child", "survivor", "other-child", "tail"],
      collapsedIDs: ["owner", "survivor", "tail"],
      ownerID: "owner"
    )

    #expect(plan == nil)
  }

  @Test("mixed insertion and removal is not disclosure")
  func rejectsMixedStructuralUpdate() {
    let plan = SidebarCollectionDisclosurePlan(
      expandedIDs: ["owner", "child", "tail"],
      collapsedIDs: ["owner", "replacement", "tail"],
      ownerID: "owner"
    )

    #expect(plan == nil)
  }

  @Test("the changed block must begin immediately after its owner")
  func rejectsDetachedBlock() {
    let plan = SidebarCollectionDisclosurePlan(
      expandedIDs: ["owner", "survivor", "child", "tail"],
      collapsedIDs: ["owner", "survivor", "tail"],
      ownerID: "owner"
    )

    #expect(plan == nil)
  }

  @Test("duplicate identity is rejected")
  func rejectsDuplicateIdentity() {
    let plan = SidebarCollectionDisclosurePlan(
      expandedIDs: ["owner", "child", "child", "tail"],
      collapsedIDs: ["owner", "tail"],
      ownerID: "owner"
    )

    #expect(plan == nil)
  }
}

@Suite("Sidebar collection disclosure timeline")
struct SidebarCollectionDisclosureTimelineTests {
  @Test("a later row stays hidden until the shared boundary reaches it")
  func sequentialReveal() {
    #expect(SidebarCollectionDisclosureTimeline.visibleFraction(
      progress: 0.4,
      rowStart: 0.5,
      rowEnd: 0.75
    ) == 0)
    #expect(SidebarCollectionDisclosureTimeline.visibleFraction(
      progress: 0.625,
      rowStart: 0.5,
      rowEnd: 0.75
    ) == 0.5)
    #expect(SidebarCollectionDisclosureTimeline.visibleFraction(
      progress: 0.8,
      rowStart: 0.5,
      rowEnd: 0.75
    ) == 1)
  }

  @Test("key progress follows either interruption direction")
  func reversibleKeyProgress() {
    #expect(SidebarCollectionDisclosureTimeline.keyProgresses(
      from: 0.2,
      to: 0.9,
      rowStart: 0.4,
      rowEnd: 0.7
    ) == [0.2, 0.4, 0.7, 0.9])
    #expect(SidebarCollectionDisclosureTimeline.keyProgresses(
      from: 0.9,
      to: 0.2,
      rowStart: 0.4,
      rowEnd: 0.7
    ) == [0.9, 0.7, 0.4, 0.2])
  }
}
