import Foundation
import Testing
@testable import InlineMacSidebarModel

private enum TestSidebarNodeID: String, Hashable, Sendable {
  case parentA
  case replyA1
  case nestedReplyA1
  case replyA2
  case rootB
  case rootC
  case folder
}

private enum TestSidebarSectionID: String, Hashable, Sendable {
  case pinned
  case normal
}

private typealias TestNode = SidebarCollectionNode<TestSidebarNodeID>
private typealias TestSection = SidebarCollectionSection<TestSidebarNodeID, TestSidebarSectionID>
private typealias TestSlot = SidebarCollectionSlot<TestSidebarNodeID, TestSidebarSectionID>
private typealias TestSnapshot = SidebarCollectionSnapshot<TestSidebarNodeID, TestSidebarSectionID>

private func node(
  _ id: TestSidebarNodeID,
  semanticParentID: TestSidebarNodeID? = nil,
  childPolicy: SidebarCollectionChildPolicy = .none,
  childIDs: [TestSidebarNodeID] = [],
  isExpanded: Bool = true
) -> TestNode {
  TestNode(
    id: id,
    semanticParentID: semanticParentID,
    childPolicy: childPolicy,
    childIDs: childIDs,
    isExpanded: isExpanded
  )
}

private func section(
  _ id: TestSidebarSectionID,
  _ rootIDs: [TestSidebarNodeID]
) -> TestSection {
  TestSection(id: id, rootIDs: rootIDs)
}

private func slot(
  _ sectionID: TestSidebarSectionID,
  parentID: TestSidebarNodeID? = nil,
  before beforeSiblingID: TestSidebarNodeID? = nil
) -> TestSlot {
  TestSlot(
    sectionID: sectionID,
    parentID: parentID,
    beforeSiblingID: beforeSiblingID
  )
}

private func standardSnapshot(parentExpanded: Bool = true) throws -> TestSnapshot {
  try TestSnapshot(
    sections: [
      section(.pinned, []),
      section(.normal, [.parentA, .rootB, .rootC]),
    ],
    nodes: [
      node(
        .parentA,
        childPolicy: .semanticParentOnly,
        childIDs: [.replyA1, .replyA2],
        isExpanded: parentExpanded
      ),
      node(.replyA1, semanticParentID: .parentA),
      node(.replyA2, semanticParentID: .parentA),
      node(.rootB, childPolicy: .semanticParentOnly),
      node(.rootC, childPolicy: .semanticParentOnly),
    ]
  )
}

private func rootIDs(
  _ snapshot: TestSnapshot,
  sectionID: TestSidebarSectionID
) -> [TestSidebarNodeID] {
  snapshot.sections.first(where: { $0.id == sectionID })?.rootIDs ?? []
}

@Suite("Sidebar collection hierarchy")
struct SidebarCollectionHierarchyTests {
  @Test("projects parent and replies as stable preorder with inherited section")
  func projectsExpandedHierarchy() throws {
    let snapshot = try standardSnapshot()
    let projected = snapshot.visibleProjection()

    #expect(projected.map(\.id) == [.parentA, .replyA1, .replyA2, .rootB, .rootC])
    #expect(projected.map(\.depth) == [0, 1, 1, 0, 0])
    #expect(projected.allSatisfy { $0.sectionID == .normal })
    #expect(snapshot.parentID(of: .replyA1) == .parentA)
  }

  @Test("collapse hides descendants but freezes the complete attached drag group")
  func collapsePreservesHierarchyAndDragMembership() throws {
    let snapshot = try TestSnapshot(
      sections: [section(.normal, [.parentA, .rootB])],
      nodes: [
        node(
          .parentA,
          childPolicy: .semanticParentOnly,
          childIDs: [.replyA1, .replyA2],
          isExpanded: false
        ),
        node(
          .replyA1,
          semanticParentID: .parentA,
          childPolicy: .semanticParentOnly,
          childIDs: [.nestedReplyA1]
        ),
        node(.nestedReplyA1, semanticParentID: .replyA1),
        node(.replyA2, semanticParentID: .parentA),
        node(.rootB),
      ]
    )

    #expect(snapshot.visibleProjection().map(\.id) == [.parentA, .rootB])
    let dragGroup = try snapshot.dragGroup(for: .parentA)
    #expect(dragGroup.visibleNodeIDs == [.parentA])
    #expect(
      dragGroup.attachedNodeIDs == [.parentA, .replyA1, .nestedReplyA1, .replyA2]
    )

    let expanded = try snapshot.settingExpanded(true, for: .parentA)
    #expect(
      expanded.visibleProjection().map(\.id)
        == [.parentA, .replyA1, .nestedReplyA1, .replyA2, .rootB]
    )
  }

  @Test("detached reply remains a semantic child while becoming a root")
  func detachedReplyRetainsSemanticParent() throws {
    let snapshot = try TestSnapshot(
      sections: [section(.normal, [.parentA, .replyA2, .rootB])],
      nodes: [
        node(
          .parentA,
          childPolicy: .semanticParentOnly,
          childIDs: [.replyA1]
        ),
        node(.replyA1, semanticParentID: .parentA),
        node(.replyA2, semanticParentID: .parentA),
        node(.rootB),
      ]
    )

    #expect(snapshot.parentID(of: .replyA2) == nil)
    #expect(snapshot.nodes[.replyA2]?.semanticParentID == .parentA)
    #expect(snapshot.visibleProjection().map(\.id) == [.parentA, .replyA1, .replyA2, .rootB])
  }

  @Test("children inherit a pinned parent's visual section")
  func pinnedParentCarriesVisibleGroup() throws {
    let snapshot = try TestSnapshot(
      sections: [
        section(.pinned, [.parentA]),
        section(.normal, [.rootB]),
      ],
      nodes: [
        node(
          .parentA,
          childPolicy: .semanticParentOnly,
          childIDs: [.replyA1]
        ),
        node(.replyA1, semanticParentID: .parentA),
        node(.rootB),
      ]
    )

    let projected = snapshot.visibleProjection()
    #expect(projected.map(\.id) == [.parentA, .replyA1, .rootB])
    #expect(projected.first(where: { $0.id == .replyA1 })?.sectionID == .pinned)
  }

  @Test("invalid cycles and duplicate placements fail deterministically")
  func rejectsInvalidTrees() {
    #expect(throws: SidebarCollectionModelError.cycle) {
      try TestSnapshot(
        sections: [section(.normal, [])],
        nodes: [
          node(.parentA, childPolicy: .any, childIDs: [.rootB]),
          node(.rootB, childPolicy: .any, childIDs: [.parentA]),
        ]
      )
    }

    #expect(throws: SidebarCollectionModelError.duplicatePlacement) {
      try TestSnapshot(
        sections: [section(.normal, [.parentA, .replyA1])],
        nodes: [
          node(.parentA, childPolicy: .any, childIDs: [.replyA1]),
          node(.replyA1),
        ]
      )
    }
  }
}

@Suite("Sidebar collection slots and moves")
struct SidebarCollectionMoveTests {
  @Test("root slots include empty pinned, first normal, every gap, and after-last")
  func exposesAllRootDestinationsWithoutSourceReservation() throws {
    let snapshot = try standardSnapshot()
    let slots = try snapshot.legalSlots(for: .parentA)
    let rootSlots = slots.filter { $0.parentID == nil }

    #expect(rootSlots == [
      slot(.pinned),
      slot(.normal, before: .rootB),
      slot(.normal, before: .rootC),
      slot(.normal),
    ])
    #expect(rootSlots.contains(slot(.normal, before: .parentA)) == false)
  }

  @Test("reply slots are sibling-scoped and never target a different semantic parent")
  func exposesOnlyLegalReplySlots() throws {
    let snapshot = try standardSnapshot()
    let slots = try snapshot.legalSlots(for: .replyA2)
    let childSlots = slots.filter { $0.parentID != nil }

    #expect(childSlots == [
      slot(.normal, parentID: .parentA, before: .replyA1),
      slot(.normal, parentID: .parentA),
    ])
    #expect(childSlots.contains(where: { $0.parentID == .rootB }) == false)
  }

  @Test("collapsed semantic parent exposes one deterministic reattach slot")
  func collapsedParentAllowsAppendWithoutHiddenSiblingGuides() throws {
    let snapshot = try TestSnapshot(
      sections: [section(.normal, [.parentA, .replyA2, .rootB])],
      nodes: [
        node(
          .parentA,
          childPolicy: .semanticParentOnly,
          childIDs: [.replyA1],
          isExpanded: false
        ),
        node(.replyA1, semanticParentID: .parentA),
        node(.replyA2, semanticParentID: .parentA),
        node(.rootB),
      ]
    )

    let childSlots = try snapshot.legalSlots(for: .replyA2).filter {
      $0.parentID != nil
    }
    #expect(childSlots == [slot(.normal, parentID: .parentA)])
  }

  @Test("moving a parent moves its attached reply subtree atomically")
  func movesParentGroupAtomically() throws {
    let snapshot = try standardSnapshot()
    let moved = try snapshot.moving(.parentA, to: slot(.normal))

    #expect(rootIDs(moved, sectionID: .normal) == [.rootB, .rootC, .parentA])
    #expect(moved.nodes[.parentA]?.childIDs == [.replyA1, .replyA2])
    #expect(moved.visibleProjection().map(\.id) == [.rootB, .rootC, .parentA, .replyA1, .replyA2])
  }

  @Test("reply can reorder, detach, and reattach only to its semantic parent")
  func reordersAndReparentsReply() throws {
    let snapshot = try standardSnapshot()
    let reordered = try snapshot.moving(
      .replyA2,
      to: slot(.normal, parentID: .parentA, before: .replyA1)
    )
    #expect(reordered.nodes[.parentA]?.childIDs == [.replyA2, .replyA1])

    let detached = try reordered.moving(
      .replyA2,
      to: slot(.normal, before: .rootB)
    )
    #expect(rootIDs(detached, sectionID: .normal) == [.parentA, .replyA2, .rootB, .rootC])
    #expect(detached.nodes[.parentA]?.childIDs == [.replyA1])
    #expect(detached.nodes[.replyA2]?.semanticParentID == .parentA)

    #expect(throws: SidebarCollectionModelError.childRejectedByContainer) {
      try detached.moving(.replyA2, to: slot(.normal, parentID: .rootB))
    }

    let reattached = try detached.moving(
      .replyA2,
      to: slot(.normal, parentID: .parentA)
    )
    #expect(reattached.nodes[.parentA]?.childIDs == [.replyA1, .replyA2])
    #expect(rootIDs(reattached, sectionID: .normal) == [.parentA, .rootB, .rootC])
  }

  @Test("future folder policy accepts arbitrary children without changing reducer")
  func futureFolderUsesSameContainmentModel() throws {
    let snapshot = try TestSnapshot(
      sections: [section(.normal, [.folder, .rootB])],
      nodes: [
        node(.folder, childPolicy: .any),
        node(.rootB),
      ]
    )

    let moved = try snapshot.moving(.rootB, to: slot(.normal, parentID: .folder))
    #expect(rootIDs(moved, sectionID: .normal) == [.folder])
    #expect(moved.nodes[.folder]?.childIDs == [.rootB])
    #expect(moved.visibleProjection().map(\.id) == [.folder, .rootB])
  }

  @Test("moving a nested reply to pinned root detaches and pins in one intent")
  func detachesIntoPinnedSection() throws {
    let snapshot = try standardSnapshot()
    let moved = try snapshot.moving(.replyA2, to: slot(.pinned))

    #expect(rootIDs(moved, sectionID: .pinned) == [.replyA2])
    #expect(moved.nodes[.parentA]?.childIDs == [.replyA1])
    #expect(moved.nodes[.replyA2]?.semanticParentID == .parentA)
  }

  @Test("source-only lane transfer leaves unpinned descendants in their original section")
  func sourceOnlyLaneTransferPromotesChildren() throws {
    let snapshot = try standardSnapshot()
    let moved = try snapshot.moving(
      .parentA,
      to: slot(.pinned),
      scope: .sourceOnly
    )

    #expect(rootIDs(moved, sectionID: .pinned) == [.parentA])
    #expect(rootIDs(moved, sectionID: .normal) == [.replyA1, .replyA2, .rootB, .rootC])
    #expect(moved.nodes[.parentA]?.childIDs.isEmpty == true)
    #expect(moved.nodes[.replyA1]?.semanticParentID == .parentA)
    #expect(moved.nodes[.replyA2]?.semanticParentID == .parentA)
  }
}

@Suite("Sidebar collection visible outline geometry")
struct SidebarCollectionVisibleOutlineTests {
  @Test("subtree end skips descendants without consuming the next sibling")
  func nestedSubtreeEndIndex() {
    let depths: [Int?] = [0, 1, 2, 3, 2, 1, 0, nil]

    #expect(
      SidebarCollectionVisibleOutline.indexAfterSubtree(
        startingAt: 1,
        depths: depths
      ) == 5
    )
    #expect(
      SidebarCollectionVisibleOutline.indexAfterSubtree(
        startingAt: 2,
        depths: depths
      ) == 4
    )
  }

  @Test("structural rows terminate a root subtree")
  func structuralRowTerminatesSubtree() {
    let depths: [Int?] = [0, 1, nil, 0]

    #expect(
      SidebarCollectionVisibleOutline.indexAfterSubtree(
        startingAt: 0,
        depths: depths
      ) == 2
    )
  }
}

@Suite("Sidebar collection stable proposal resolution")
struct SidebarCollectionSlotResolverTests {
  @Test("stationary pointer retains one slot and hysteresis prevents boundary wobble")
  func stableResolutionAndHysteresis() {
    let pinned = slot(.pinned)
    let firstNormal = slot(.normal, before: .rootB)
    let guides = [
      SidebarCollectionSlotGuide(slot: pinned, position: 0),
      SidebarCollectionSlotGuide(slot: firstNormal, position: 10),
    ]

    let tie = SidebarCollectionSlotResolver.resolve(
      position: 5,
      guides: guides,
      currentSlot: firstNormal,
      hysteresis: 2
    )
    #expect(tie == firstNormal)

    let stillNormal = SidebarCollectionSlotResolver.resolve(
      position: 4,
      guides: guides,
      currentSlot: firstNormal,
      hysteresis: 2
    )
    #expect(stillNormal == firstNormal)

    let crossed = SidebarCollectionSlotResolver.resolve(
      position: 3.9,
      guides: guides,
      currentSlot: firstNormal,
      hysteresis: 2
    )
    #expect(crossed == pinned)

    let stationary = SidebarCollectionSlotResolver.resolve(
      position: 3.9,
      guides: guides,
      currentSlot: crossed,
      hysteresis: 2
    )
    #expect(stationary == crossed)
  }
}

@Suite("Sidebar collection optimistic reconciliation")
struct SidebarCollectionOptimisticStateTests {
  private let firstMoveID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  private let secondMoveID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

  @Test("drop presents once, RPC ack does not move again, model observation settles silently")
  func optimisticDropAcknowledgesWithoutSecondPresentation() throws {
    let snapshot = try standardSnapshot()
    let expected = try snapshot.moving(.parentA, to: slot(.normal))
    var state = SidebarCollectionOptimisticState(confirmed: snapshot)

    let changed = try state.beginMove(
      id: firstMoveID,
      sourceID: .parentA,
      destination: slot(.normal)
    )
    #expect(changed)
    #expect(state.presented == expected)
    #expect(state.pendingMoves.count == 1)

    let beforeAcknowledgement = state.presented
    let acknowledgedRPC = state.acknowledgeRPC(id: firstMoveID)
    #expect(acknowledgedRPC)
    #expect(state.presented == beforeAcknowledgement)

    let reconciliation = state.receiveExternal(expected)
    #expect(reconciliation.acknowledgedMoveIDs == [firstMoveID])
    #expect(reconciliation.presentationChanged == false)
    #expect(state.pendingMoves.isEmpty)
    #expect(state.presented == expected)
  }

  @Test("source-only scope survives optimistic replay and acknowledgement")
  func sourceOnlyScopeReplays() throws {
    let snapshot = try standardSnapshot()
    let destination = slot(.pinned)
    let expected = try snapshot.moving(
      .parentA,
      to: destination,
      scope: .sourceOnly
    )
    var state = SidebarCollectionOptimisticState(confirmed: snapshot)

    try state.beginMove(
      id: firstMoveID,
      sourceID: .parentA,
      destination: destination,
      scope: .sourceOnly
    )
    #expect(state.presented == expected)
    #expect(state.pendingMoves.first?.scope == .sourceOnly)

    let acknowledgedRPC = state.acknowledgeRPC(id: firstMoveID)
    #expect(acknowledgedRPC)
    let reconciliation = state.receiveExternal(expected)
    #expect(reconciliation.acknowledgedMoveIDs == [firstMoveID])
    #expect(state.pendingMoves.isEmpty)
  }

  @Test("external changes rebase pending move and failure rolls back exactly once")
  func rebaseThenRollbackOnce() throws {
    let snapshot = try standardSnapshot()
    var state = SidebarCollectionOptimisticState(confirmed: snapshot)
    try state.beginMove(
      id: firstMoveID,
      sourceID: .parentA,
      destination: slot(.normal)
    )

    let external = try snapshot.moving(
      .rootC,
      to: slot(.normal, before: .rootB)
    )
    let reconciliation = state.receiveExternal(external)
    #expect(reconciliation.acknowledgedMoveIDs.isEmpty)
    #expect(reconciliation.cancelledMoveIDs.isEmpty)
    #expect(rootIDs(state.presented, sectionID: .normal) == [.rootC, .rootB, .parentA])

    let rolledBack = state.failMove(id: firstMoveID)
    #expect(rolledBack)
    #expect(state.presented == external)
    let repeatedRollback = state.failMove(id: firstMoveID)
    #expect(repeatedRollback == false)
    #expect(state.presented == external)
  }

  @Test("matching visible order in the wrong section does not acknowledge")
  func wrongSectionCannotAcknowledgeMove() throws {
    let snapshot = try standardSnapshot()
    let expected = try snapshot.moving(.parentA, to: slot(.pinned))
    var state = SidebarCollectionOptimisticState(confirmed: snapshot)

    try state.beginMove(
      id: firstMoveID,
      sourceID: .parentA,
      destination: slot(.pinned)
    )
    let didAcknowledgeRPC = state.acknowledgeRPC(id: firstMoveID)
    #expect(didAcknowledgeRPC)

    let stale = state.receiveExternal(snapshot)
    #expect(stale.acknowledgedMoveIDs.isEmpty)
    #expect(state.pendingMoves.map(\.id) == [firstMoveID])
    #expect(state.presented == expected)

    let settled = state.receiveExternal(expected)
    #expect(settled.acknowledgedMoveIDs == [firstMoveID])
    #expect(state.pendingMoves.isEmpty)
  }

  @Test("matching root order with the wrong hierarchy does not acknowledge")
  func wrongHierarchyCannotAcknowledgeMove() throws {
    let snapshot = try standardSnapshot()
    let destination = slot(.normal, before: .rootB)
    let expected = try snapshot.moving(.replyA2, to: destination)
    var state = SidebarCollectionOptimisticState(confirmed: snapshot)

    try state.beginMove(
      id: firstMoveID,
      sourceID: .replyA2,
      destination: destination
    )
    let didAcknowledgeRPC = state.acknowledgeRPC(id: firstMoveID)
    #expect(didAcknowledgeRPC)

    let stale = state.receiveExternal(snapshot)
    #expect(stale.acknowledgedMoveIDs.isEmpty)
    #expect(state.pendingMoves.map(\.id) == [firstMoveID])
    #expect(state.presented == expected)

    let settled = state.receiveExternal(expected)
    #expect(settled.acknowledgedMoveIDs == [firstMoveID])
    #expect(state.pendingMoves.isEmpty)
  }

  @Test("missing source cancels pending intent against newest external snapshot")
  func sourceDeletionCancelsPendingMove() throws {
    let snapshot = try standardSnapshot()
    var state = SidebarCollectionOptimisticState(confirmed: snapshot)
    try state.beginMove(
      id: firstMoveID,
      sourceID: .parentA,
      destination: slot(.normal)
    )
    let withoutSource = try TestSnapshot(
      sections: [
        section(.pinned, []),
        section(.normal, [.rootB, .rootC]),
      ],
      nodes: [node(.rootB), node(.rootC)]
    )

    let reconciliation = state.receiveExternal(withoutSource)
    #expect(reconciliation.cancelledMoveIDs == [firstMoveID])
    #expect(state.pendingMoves.isEmpty)
    #expect(state.presented == withoutSource)
  }

  @Test("newer move for same source supersedes stale completion and remains compensating")
  func rapidMoveCoalescesBySource() throws {
    let snapshot = try standardSnapshot()
    var state = SidebarCollectionOptimisticState(confirmed: snapshot)
    try state.beginMove(
      id: firstMoveID,
      sourceID: .parentA,
      destination: slot(.normal)
    )
    try state.beginMove(
      id: secondMoveID,
      sourceID: .parentA,
      destination: slot(.normal, before: .rootB)
    )

    #expect(state.presented == snapshot)
    #expect(state.pendingMoves.map(\.id) == [secondMoveID])
    let staleFailureHandled = state.failMove(id: firstMoveID)
    #expect(staleFailureHandled == false)
    #expect(state.presented == snapshot)

    let staleExternal = try snapshot.moving(.parentA, to: slot(.normal))
    let reconciliation = state.receiveExternal(staleExternal)
    #expect(reconciliation.acknowledgedMoveIDs.isEmpty)
    #expect(rootIDs(state.presented, sectionID: .normal) == [.parentA, .rootB, .rootC])
    #expect(state.pendingMoves.map(\.id) == [secondMoveID])

    let acknowledgedRPC = state.acknowledgeRPC(id: secondMoveID)
    #expect(acknowledgedRPC)
    let finalExternal = snapshot
    _ = state.receiveExternal(finalExternal)
    #expect(state.pendingMoves.isEmpty)
    #expect(state.presented == finalExternal)
  }

  @Test("superseding one source rejects invalidating a cross-source dependency")
  func sourceReplacementRejectsDependentMove() throws {
    let snapshot = try standardSnapshot()
    let thirdMoveID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    var state = SidebarCollectionOptimisticState(confirmed: snapshot)

    try state.beginMove(
      id: firstMoveID,
      sourceID: .replyA2,
      destination: slot(.normal, before: .rootB)
    )
    try state.beginMove(
      id: secondMoveID,
      sourceID: .rootB,
      destination: slot(.normal, before: .replyA2)
    )

    let previousPresentation = state.presented
    #expect(throws: SidebarCollectionModelError.pendingMoveDependency) {
      try state.beginMove(
        id: thirdMoveID,
        sourceID: .replyA2,
        destination: slot(.normal, parentID: .parentA)
      )
    }

    #expect(state.pendingMoves.map(\.id) == [firstMoveID, secondMoveID])
    #expect(state.presented == previousPresentation)
  }
}
