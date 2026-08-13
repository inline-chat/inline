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
}
