import Testing
@testable import InlineMacSidebarModel

@Suite("Sidebar root ordering")
struct SidebarCollectionRootOrderingTests {
  @Test("temporary roots stay at the configured top edge")
  func anchorsAtTop() {
    let roots = SidebarCollectionRootOrdering.anchoring(
      Set(["temporary-parent"]),
      atStart: true,
      in: ["persisted-first", "persisted-second", "temporary-parent"]
    )

    #expect(roots == ["temporary-parent", "persisted-first", "persisted-second"])
  }

  @Test("temporary roots stay at the configured bottom edge")
  func anchorsAtBottom() {
    let roots = SidebarCollectionRootOrdering.anchoring(
      Set(["temporary-parent"]),
      atStart: false,
      in: ["temporary-parent", "persisted-first", "persisted-second"]
    )

    #expect(roots == ["persisted-first", "persisted-second", "temporary-parent"])
  }

  @Test("temporary children do not uproot a persisted parent")
  func ignoresNonRootIDs() {
    let roots = SidebarCollectionRootOrdering.anchoring(
      Set(["temporary-reply"]),
      atStart: true,
      in: ["persisted-parent", "other"]
    )

    #expect(roots == ["persisted-parent", "other"])
  }
}
