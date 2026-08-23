import Testing
@testable import InlineMacSidebarModel

@Suite("Sidebar scroll-edge visibility")
struct SidebarScrollEdgeVisibilityTests {
  @Test("short content has no edge affordances")
  func shortContent() {
    #expect(SidebarScrollEdgeVisibility.resolve(
      viewportStart: 0,
      viewportLength: 500,
      contentLength: 300
    ) == .init(top: false, bottom: false))
  }

  @Test("trailing document padding does not become a content edge")
  func trailingPaddingIsNotContent() {
    #expect(SidebarScrollEdgeVisibility.resolve(
      viewportStart: 20,
      viewportLength: 500,
      contentLength: 500
    ) == .init(top: false, bottom: false))
  }

  @Test("top, middle, and bottom expose only reachable directions")
  func scrollPositions() {
    #expect(SidebarScrollEdgeVisibility.resolve(
      viewportStart: 0,
      viewportLength: 100,
      contentLength: 300
    ) == .init(top: false, bottom: true))
    #expect(SidebarScrollEdgeVisibility.resolve(
      viewportStart: 100,
      viewportLength: 100,
      contentLength: 300
    ) == .init(top: true, bottom: true))
    #expect(SidebarScrollEdgeVisibility.resolve(
      viewportStart: 200,
      viewportLength: 100,
      contentLength: 300
    ) == .init(top: true, bottom: false))
  }

  @Test("prominent unread targets stay nearest to the viewport")
  func prominentUnreadTargets() {
    let entries = [
      SidebarUnreadViewportEntry(id: "far-above", minimumY: 0, maximumY: 20, isProminentUnread: true),
      SidebarUnreadViewportEntry(id: "muted-above", minimumY: 20, maximumY: 40, isProminentUnread: false),
      SidebarUnreadViewportEntry(id: "near-above", minimumY: 40, maximumY: 60, isProminentUnread: true),
      SidebarUnreadViewportEntry(id: "visible", minimumY: 60, maximumY: 80, isProminentUnread: true),
      SidebarUnreadViewportEntry(id: "near-below", minimumY: 80, maximumY: 100, isProminentUnread: true),
      SidebarUnreadViewportEntry(id: "far-below", minimumY: 100, maximumY: 120, isProminentUnread: true),
    ]

    let result = SidebarUnreadViewportResolver.resolve(
      entries: entries,
      viewportStart: 60,
      viewportLength: 20
    )

    #expect(result.above == .init(count: 2, targetID: "near-above"))
    #expect(result.below == .init(count: 2, targetID: "near-below"))
  }

  @Test("partially visible unread rows are not outside the viewport")
  func partialVisibility() {
    let entries = [
      SidebarUnreadViewportEntry(id: 1, minimumY: 40, maximumY: 70, isProminentUnread: true),
      SidebarUnreadViewportEntry(id: 2, minimumY: 90, maximumY: 120, isProminentUnread: true),
    ]

    let result = SidebarUnreadViewportResolver.resolve(
      entries: entries,
      viewportStart: 60,
      viewportLength: 40
    )

    #expect(result.above == nil)
    #expect(result.below == nil)
  }

  @Test("collapsed containers contribute their complete prominent unread count")
  func weightedContainerUnreadCount() {
    let entries = [
      SidebarUnreadViewportEntry(
        id: "folder",
        minimumY: 100,
        maximumY: 130,
        prominentUnreadCount: 3
      ),
    ]

    let result = SidebarUnreadViewportResolver.resolve(
      entries: entries,
      viewportStart: 0,
      viewportLength: 80
    )

    #expect(result.below == .init(count: 3, targetID: "folder"))
  }

  @Test("nearby unread targets animate from the current position")
  func nearbyUnreadScrollPlan() {
    let plan = SidebarUnreadScrollPlan.resolve(
      currentOffset: 100,
      targetMinimum: 300,
      targetMaximum: 344,
      viewportLength: 400,
      contentLength: 2_000
    )

    #expect(plan.targetOffset == 122)
    #expect(plan.animatedStartOffset == 100)
    #expect(plan.usesLongDistanceJump == false)
  }

  @Test("distant unread targets animate only the final viewport")
  func distantUnreadScrollPlan() {
    let below = SidebarUnreadScrollPlan.resolve(
      currentOffset: 0,
      targetMinimum: 1_400,
      targetMaximum: 1_444,
      viewportLength: 400,
      contentLength: 2_000
    )
    #expect(below.targetOffset == 1_222)
    #expect(below.animatedStartOffset == 822)
    #expect(below.usesLongDistanceJump)

    let above = SidebarUnreadScrollPlan.resolve(
      currentOffset: 1_500,
      targetMinimum: 200,
      targetMaximum: 244,
      viewportLength: 400,
      contentLength: 2_000
    )
    #expect(above.targetOffset == 22)
    #expect(above.animatedStartOffset == 422)
    #expect(above.usesLongDistanceJump)
  }

  @Test("unread scroll destinations clamp to content edges")
  func unreadScrollPlanClampsToEdges() {
    let top = SidebarUnreadScrollPlan.resolve(
      currentOffset: 300,
      targetMinimum: 0,
      targetMaximum: 44,
      viewportLength: 400,
      contentLength: 1_000
    )
    #expect(top.targetOffset == 0)

    let bottom = SidebarUnreadScrollPlan.resolve(
      currentOffset: 0,
      targetMinimum: 956,
      targetMaximum: 1_000,
      viewportLength: 400,
      contentLength: 1_000
    )
    #expect(bottom.targetOffset == 600)
  }
}
