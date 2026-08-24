import Testing
@testable import InlineMacSidebarModel

@Suite("Sidebar reorder policy")
struct SidebarCollectionReorderPolicyTests {
  @Test("manual mode permits lane, sibling, and hierarchy moves")
  func manualPolicy() {
    let policy = SidebarCollectionReorderPolicy.manual
    #expect(policy.allowsMove(
      sourceIsRoot: false,
      changesSection: false,
      changesParent: true
    ))
  }

  @Test("pinning mode permits root lane transfers and pinned-container entry")
  func pinningOnlyPolicy() {
    let policy = SidebarCollectionReorderPolicy.pinningOnly
    #expect(policy.allowsMove(
      sourceIsRoot: true,
      changesSection: true,
      changesParent: false
    ))
    #expect(!policy.allowsMove(
      sourceIsRoot: true,
      changesSection: false,
      changesParent: false
    ))
    #expect(!policy.allowsMove(
      sourceIsRoot: false,
      changesSection: true,
      changesParent: true
    ))
    #expect(policy.allowsMove(
      sourceIsRoot: false,
      changesSection: false,
      changesParent: true,
      entersPinnedContainer: true
    ))
  }
}
