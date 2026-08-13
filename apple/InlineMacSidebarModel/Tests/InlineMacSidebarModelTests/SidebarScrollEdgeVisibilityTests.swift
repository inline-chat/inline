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
}
