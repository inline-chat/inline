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

  @Test("activity mode permits pinning, pinned order, and folder membership changes")
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
      changesSection: true,
      changesParent: true,
      changesFolderMembership: true
    ))
    #expect(policy.allowsMove(
      sourceIsRoot: false,
      changesSection: false,
      changesParent: true,
      changesFolderMembership: true
    ))
    #expect(policy.allowsMove(
      sourceIsRoot: true,
      changesSection: false,
      changesParent: false,
      reordersPinnedLane: true
    ))
  }

  @Test("folder policy permits lane transfer and reorder within either stable lane")
  func folderPolicy() {
    let policy = SidebarCollectionReorderPolicy.pinningOnly
    #expect(policy.allowsFolderMove(
      changesSection: true,
      reordersStableLane: false
    ))
    #expect(policy.allowsFolderMove(
      changesSection: false,
      reordersStableLane: true
    ))
    #expect(!policy.allowsFolderMove(
      changesSection: false,
      reordersStableLane: false
    ))
    #expect(SidebarCollectionReorderPolicy.manual.allowsFolderMove(
      changesSection: false,
      reordersStableLane: false
    ))
  }
}
