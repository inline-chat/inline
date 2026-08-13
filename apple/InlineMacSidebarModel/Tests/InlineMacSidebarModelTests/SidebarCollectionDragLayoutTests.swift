import Testing
@testable import InlineMacSidebarModel

private enum DragRowID: Hashable, Sendable {
  case pinnedHeader
  case pinGuide
  case contentHeader
  case parent
  case reply
  case next
}

private typealias DragRow = SidebarCollectionDragLayoutRow<DragRowID>
private typealias DragState = SidebarCollectionDragLayoutState<DragRowID>

private func frame(
  _ result: SidebarCollectionDragLayoutResult<DragRowID>,
  _ id: DragRowID
) -> SidebarCollectionVerticalFrame? {
  result.rowFrames[id]
}

@Suite("Sidebar collection frozen drag layout")
struct SidebarCollectionDragLayoutTests {
  @Test("lifting starts with one source-sized hole and unchanged surrounding geometry")
  func originalSlotDoesNotJump() {
    let rows = [
      DragRow(id: .contentHeader, height: 28),
      DragRow(id: .parent, height: 44),
      DragRow(id: .next, height: 44),
    ]
    let result = SidebarCollectionDragLayoutPlanner.plan(
      rows: rows,
      drag: DragState(
        sourceIDs: [.parent],
        destinationIndex: 1,
        slotHeight: 44
      )
    )

    #expect(result.slotFrame == SidebarCollectionVerticalFrame(minY: 28, height: 44))
    #expect(frame(result, .next)?.minY == 72)
    #expect(result.visibleRowIDs.contains(.parent) == false)
    #expect(result.contentHeight == 116)
  }

  @Test("a group owns one hole equal to its full visible footprint")
  func groupUsesOneCompleteHole() {
    let rows = [
      DragRow(id: .contentHeader, height: 28),
      DragRow(id: .parent, height: 44),
      DragRow(id: .reply, height: 44),
      DragRow(id: .next, height: 44),
    ]
    let result = SidebarCollectionDragLayoutPlanner.plan(
      rows: rows,
      drag: DragState(
        sourceIDs: [.parent, .reply],
        destinationIndex: 2,
        slotHeight: 88
      )
    )

    #expect(frame(result, .next)?.minY == 28)
    #expect(result.slotFrame == SidebarCollectionVerticalFrame(minY: 72, height: 88))
    #expect(result.contentHeight == 160)
  }

  @Test("empty Pinned is absent until its semantic lane becomes active")
  func emptyPinnedTargetIsContextualAndIsTheOnlyHole() {
    let rows = [
      DragRow(id: .pinnedHeader, height: 0, role: .pinnedHeader),
      DragRow(id: .pinGuide, height: 0, role: .emptyPinnedGuide),
      DragRow(id: .contentHeader, height: 28),
      DragRow(id: .parent, height: 44),
      DragRow(id: .next, height: 44),
    ]
    let original = SidebarCollectionDragLayoutPlanner.plan(
      rows: rows,
      drag: DragState(
        sourceIDs: [.parent],
        destinationIndex: 3,
        slotHeight: 44
      )
    )
    #expect(frame(original, .pinnedHeader)?.height == 0)
    #expect(frame(original, .pinGuide)?.height == 0)
    #expect(original.slotFrame == SidebarCollectionVerticalFrame(minY: 28, height: 44))
    #expect(frame(original, .next)?.minY == 72)

    let pinned = SidebarCollectionDragLayoutPlanner.plan(
      rows: rows,
      drag: DragState(
        sourceIDs: [.parent],
        destinationIndex: 1,
        slotHeight: 44,
        showsEmptyPinnedTarget: true,
        emptyPinnedHeaderHeight: 28
      )
    )
    #expect(frame(pinned, .pinnedHeader)?.height == 28)
    #expect(frame(pinned, .pinGuide) == pinned.slotFrame)
    #expect(pinned.slotFrame == SidebarCollectionVerticalFrame(minY: 28, height: 44))
    #expect(frame(pinned, .contentHeader)?.minY == 72)
  }

  @Test("returning the destination to the original slot restores one exact scene")
  func cancellationRestoresOriginalScene() {
    let rows = [
      DragRow(id: .contentHeader, height: 28),
      DragRow(id: .parent, height: 44),
      DragRow(id: .next, height: 44),
    ]
    let originalState = DragState(
      sourceIDs: [.parent],
      destinationIndex: 1,
      slotHeight: 44
    )
    let moved = SidebarCollectionDragLayoutPlanner.plan(
      rows: rows,
      drag: DragState(
        sourceIDs: [.parent],
        destinationIndex: 2,
        slotHeight: 44
      )
    )
    let restored = SidebarCollectionDragLayoutPlanner.plan(rows: rows, drag: originalState)
    let baseline = SidebarCollectionDragLayoutPlanner.plan(rows: rows, drag: originalState)

    #expect(moved.slotFrame?.minY == 72)
    #expect(restored.slotFrame == baseline.slotFrame)
    #expect(restored.rowFrames == baseline.rowFrames)
    #expect(restored.visibleRowIDs == baseline.visibleRowIDs)
  }

  @Test("an emptied real Pinned lane can hide its header without another gap")
  func hidesEmptiedPinnedHeader() {
    let rows = [
      DragRow(id: .pinnedHeader, height: 28, role: .pinnedHeader),
      DragRow(id: .parent, height: 44),
      DragRow(id: .contentHeader, height: 28),
      DragRow(id: .next, height: 44),
    ]
    let result = SidebarCollectionDragLayoutPlanner.plan(
      rows: rows,
      drag: DragState(
        sourceIDs: [.parent],
        destinationIndex: 2,
        slotHeight: 44,
        hidesPinnedHeader: true
      )
    )

    #expect(frame(result, .pinnedHeader)?.height == 0)
    #expect(frame(result, .contentHeader)?.minY == 0)
    #expect(result.slotFrame == SidebarCollectionVerticalFrame(minY: 28, height: 44))
  }

  @Test("all proposal guides are derived in one source-removed pass")
  func derivesEverySlotPositionInOnePass() {
    let rows = [
      DragRow(id: .pinnedHeader, height: 0, role: .pinnedHeader),
      DragRow(id: .pinGuide, height: 0, role: .emptyPinnedGuide),
      DragRow(id: .contentHeader, height: 28),
      DragRow(id: .parent, height: 44),
      DragRow(id: .reply, height: 44),
      DragRow(id: .next, height: 44),
    ]

    let normal = SidebarCollectionDragLayoutPlanner.slotPositions(
      rows: rows,
      sourceIDs: [.parent, .reply]
    )
    #expect(normal == [0: 0, 1: 0, 2: 0, 3: 28, 4: 72])

    let emptyPinned = SidebarCollectionDragLayoutPlanner.slotPositions(
      rows: rows,
      sourceIDs: [.parent, .reply],
      showsEmptyPinnedTarget: true,
      emptyPinnedHeaderHeight: 28
    )
    #expect(emptyPinned[1] == 28)
    #expect(emptyPinned[4] == 100)
  }

  @Test("sorted proposal lookup is stable at ties and crosses hysteresis once")
  func sortedProposalLookupIsStable() {
    let positions = [0.0, 10.0, 20.0, 30.0]

    #expect(
      SidebarCollectionSortedPositionResolver.resolve(
        position: 15,
        sortedPositions: positions,
        currentIndex: 2,
        hysteresis: 2
      ) == 2
    )
    #expect(
      SidebarCollectionSortedPositionResolver.resolve(
        position: 14,
        sortedPositions: positions,
        currentIndex: 2,
        hysteresis: 2
      ) == 2
    )
    #expect(
      SidebarCollectionSortedPositionResolver.resolve(
        position: 13.9,
        sortedPositions: positions,
        currentIndex: 2,
        hysteresis: 2
      ) == 1
    )
    #expect(
      SidebarCollectionSortedPositionResolver.resolve(
        position: -100,
        sortedPositions: positions,
        currentIndex: nil
      ) == 0
    )
    #expect(
      SidebarCollectionSortedPositionResolver.resolve(
        position: 100,
        sortedPositions: positions,
        currentIndex: nil
      ) == 3
    )
  }
}
