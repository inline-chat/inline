import Testing
@testable import InlineMacSidebarModel

@Suite("Sidebar drop navigation")
struct SidebarDropNavigationPolicyTests {
  @Test(
    "only an attached reply with the preference enabled opens in a side pane",
    arguments: [
      (false, false, SidebarDropNavigationPresentation.primary),
      (false, true, SidebarDropNavigationPresentation.primary),
      (true, false, SidebarDropNavigationPresentation.primary),
      (true, true, SidebarDropNavigationPresentation.replySidePane),
    ]
  )
  func presentation(
    presentationParentExists: Bool,
    prefersReplySidePane: Bool,
    expected: SidebarDropNavigationPresentation
  ) {
    #expect(SidebarDropNavigationPolicy.presentation(
      presentationParentExists: presentationParentExists,
      prefersReplySidePane: prefersReplySidePane
    ) == expected)
  }

  @Test("a semantically related but presentation-detached reply opens in the primary pane")
  func detachedReplyUsesPresentationParent() throws {
    let snapshot = try SidebarCollectionSnapshot(
      sections: [
        SidebarCollectionSection(id: "inbox", rootIDs: ["parent", "reply"]),
      ],
      nodes: [
        SidebarCollectionNode(
          id: "parent",
          childPolicy: .semanticParentOnly
        ),
        SidebarCollectionNode(
          id: "reply",
          semanticParentID: "parent"
        ),
      ]
    )

    #expect(snapshot.nodes["reply"]?.semanticParentID == "parent")
    #expect(snapshot.parentID(of: "reply") == nil)
    #expect(SidebarDropNavigationPolicy.presentation(
      presentationParentExists: snapshot.parentID(of: "reply") != nil,
      prefersReplySidePane: true
    ) == .primary)
  }
}
