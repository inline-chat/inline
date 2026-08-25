import Testing
@testable import InlineMacSidebarModel

private enum DragRowID: Hashable, Sendable {
  case navigation
  case pinnedHeader
  case pinGuide
  case contentHeader
  case newThread
  case parent
  case reply
  case folderPlaceholder
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
  @Test("vertical hit resolution never assigns the gap between rows")
  func verticalHitResolutionRequiresContainment() {
    let guides = [
      SidebarCollectionVerticalHitGuide(minY: 0, middleY: 15, maxY: 30),
      SidebarCollectionVerticalHitGuide(minY: 32, middleY: 47, maxY: 62),
    ]

    #expect(SidebarCollectionVerticalHitResolver.resolve(
      position: 15,
      sortedGuides: guides
    ) == 0)
    #expect(SidebarCollectionVerticalHitResolver.resolve(
      position: 31,
      sortedGuides: guides
    ) == nil)
    #expect(SidebarCollectionVerticalHitResolver.resolve(
      position: 47,
      sortedGuides: guides
    ) == 1)
  }

  @Test("an extended container guide owns its empty placeholder")
  func verticalHitResolutionSupportsEmptyContainerArea() {
    let guides = [
      SidebarCollectionVerticalHitGuide(minY: 0, middleY: 30, maxY: 60),
      SidebarCollectionVerticalHitGuide(minY: 61, middleY: 76, maxY: 91),
    ]

    #expect(SidebarCollectionVerticalHitResolver.resolve(
      position: 52,
      sortedGuides: guides
    ) == 0)
  }

  @Test("touching hit ranges resolve to the nearest row center")
  func verticalHitResolutionBreaksBoundaryTiesByCenter() {
    let guides = [
      SidebarCollectionVerticalHitGuide(minY: 0, middleY: 10, maxY: 20),
      SidebarCollectionVerticalHitGuide(minY: 20, middleY: 30, maxY: 40),
    ]

    #expect(SidebarCollectionVerticalHitResolver.resolve(
      position: 20,
      sortedGuides: guides
    ) == 0)
    #expect(SidebarCollectionVerticalHitResolver.resolve(
      position: 21,
      sortedGuides: guides
    ) == 1)
  }

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

  @Test("an empty folder placeholder owns its child destination instead of becoming a sibling")
  func emptyFolderPlaceholderReusesDestinationSlot() {
    let rows = [
      DragRow(id: .contentHeader, height: 28),
      DragRow(id: .parent, height: 44),
      DragRow(id: .folderPlaceholder, height: 44, role: .emptyFolderGuide),
      DragRow(id: .next, height: 44),
    ]
    let result = SidebarCollectionDragLayoutPlanner.plan(
      rows: rows,
      drag: DragState(
        sourceIDs: [.next],
        destinationIndex: 2,
        slotHeight: 44
      )
    )

    #expect(frame(result, .folderPlaceholder) == .init(minY: 72, height: 44))
    #expect(result.slotFrame == frame(result, .folderPlaceholder))
    #expect(result.contentHeight == 116)
  }

  @Test("an empty folder placeholder expands only when a grouped child needs more room")
  func emptyFolderPlaceholderFitsGroupedDestination() {
    let rows = [
      DragRow(id: .contentHeader, height: 28),
      DragRow(id: .parent, height: 44),
      DragRow(id: .folderPlaceholder, height: 44, role: .emptyFolderGuide),
      DragRow(id: .reply, height: 44),
      DragRow(id: .next, height: 44),
    ]
    let result = SidebarCollectionDragLayoutPlanner.plan(
      rows: rows,
      drag: DragState(
        sourceIDs: [.reply, .next],
        destinationIndex: 2,
        slotHeight: 88
      )
    )

    #expect(frame(result, .folderPlaceholder) == .init(minY: 72, height: 88))
    #expect(result.slotFrame == frame(result, .folderPlaceholder))
    #expect(result.contentHeight == 160)
  }

  @Test("empty Pinned is absent until its conditional presentation is active")
  func emptyPinnedTargetIsContextualAndOwnsThePinnedHole() {
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

    let idle = SidebarCollectionDragLayoutPlanner.plan(rows: rows, drag: nil)
    #expect(frame(idle, .pinnedHeader)?.height == 0)
    #expect(frame(idle, .pinGuide)?.height == 0)
    #expect(idle.visibleRowIDs.contains(.pinnedHeader) == false)
    #expect(idle.visibleRowIDs.contains(.pinGuide) == false)
    #expect(frame(idle, .contentHeader)?.minY == 0)

    let pinned = SidebarCollectionDragLayoutPlanner.plan(
      rows: rows,
      drag: DragState(
        sourceIDs: [.parent],
        destinationIndex: 1,
        slotHeight: 44
      ),
      emptyPinned: SidebarCollectionEmptyPinnedLayoutState(
        headerHeight: 28,
        targetHeight: 56
      )
    )
    #expect(frame(pinned, .pinnedHeader)?.height == 28)
    #expect(frame(pinned, .pinGuide) == pinned.slotFrame)
    #expect(pinned.slotFrame == SidebarCollectionVerticalFrame(minY: 28, height: 56))
    #expect(frame(pinned, .contentHeader)?.minY == 84)

    let idleAfterDrag = SidebarCollectionDragLayoutPlanner.plan(rows: rows, drag: nil)
    #expect(idleAfterDrag.rowFrames == idle.rowFrames)
    #expect(idleAfterDrag.visibleRowIDs == idle.visibleRowIDs)
    #expect(idleAfterDrag.contentHeight == idle.contentHeight)
  }

  @Test("latent Open separator adds no empty-section geometry")
  func latentOpenSeparatorCollapsesWithoutDisturbingPinnedDropRows() {
    let emptyOpenRows = [
      DragRow(id: .navigation, height: 44),
      DragRow(id: .pinnedHeader, height: 0, role: .pinnedHeader),
      DragRow(id: .pinGuide, height: 0, role: .emptyPinnedGuide),
      DragRow(id: .contentHeader, height: 0),
      DragRow(id: .newThread, height: 44),
    ]
    let emptyOpen = SidebarCollectionDragLayoutPlanner.plan(
      rows: emptyOpenRows,
      drag: nil
    )

    #expect(frame(emptyOpen, .pinnedHeader)?.height == 0)
    #expect(frame(emptyOpen, .pinGuide)?.height == 0)
    #expect(frame(emptyOpen, .contentHeader)?.height == 0)
    #expect(emptyOpen.visibleRowIDs.contains(.contentHeader) == false)
    #expect(frame(emptyOpen, .newThread)?.minY == 44)
    #expect(emptyOpen.contentHeight == 88)

    let populatedOpen = SidebarCollectionDragLayoutPlanner.plan(
      rows: emptyOpenRows.map { row in
        row.id == .contentHeader
          ? DragRow(id: row.id, height: 14, role: row.role)
          : row
      },
      drag: nil
    )
    #expect(frame(populatedOpen, .contentHeader)?.height == 14)
    #expect(frame(populatedOpen, .newThread)?.minY == 58)
    #expect(populatedOpen.contentHeight == 102)
  }

  @Test("untitled Pinned spacer adds only the calibrated lane spacing")
  func pinnedSpacerPrecedesPinnedItemsAndOpenSeparator() {
    let rows = [
      DragRow(id: .navigation, height: 44),
      DragRow(id: .pinnedHeader, height: 6, role: .pinnedHeader),
      DragRow(id: .parent, height: 44),
      DragRow(id: .contentHeader, height: 14),
      DragRow(id: .newThread, height: 44),
      DragRow(id: .next, height: 44),
    ]
    let result = SidebarCollectionDragLayoutPlanner.plan(rows: rows, drag: nil)

    #expect(frame(result, .pinnedHeader) == .init(minY: 44, height: 6))
    #expect(frame(result, .parent)?.minY == 50)
    #expect(frame(result, .contentHeader) == .init(minY: 94, height: 14))
    #expect(frame(result, .newThread)?.minY == 108)
    #expect(frame(result, .next)?.minY == 152)
    #expect(result.contentHeight == 196)
  }

  @Test("empty Pinned drag reveal reuses the compact Inbox lead-in")
  func emptyPinnedDragRevealUsesPinnedSpacerHeight() {
    let rows = [
      DragRow(id: .navigation, height: 44),
      DragRow(id: .pinnedHeader, height: 0, role: .pinnedHeader),
      DragRow(id: .pinGuide, height: 0, role: .emptyPinnedGuide),
      DragRow(id: .contentHeader, height: 14),
      DragRow(id: .newThread, height: 44),
    ]
    let result = SidebarCollectionDragLayoutPlanner.plan(
      rows: rows,
      drag: nil,
      emptyPinned: .init(headerHeight: 6, targetHeight: 56)
    )

    #expect(frame(result, .pinnedHeader) == .init(minY: 44, height: 6))
    #expect(frame(result, .pinGuide) == .init(minY: 50, height: 56))
    #expect(frame(result, .contentHeader) == .init(minY: 106, height: 14))
    #expect(frame(result, .newThread)?.minY == 120)
    #expect(result.contentHeight == 164)
  }

  @Test("conditional empty Pinned remains real geometry at a normal destination")
  func emptyPinnedPersistsOutsidePinnedDestination() {
    let rows = [
      DragRow(id: .pinnedHeader, height: 0, role: .pinnedHeader),
      DragRow(id: .pinGuide, height: 0, role: .emptyPinnedGuide),
      DragRow(id: .contentHeader, height: 28),
      DragRow(id: .parent, height: 44),
      DragRow(id: .next, height: 44),
    ]
    let conditionalPinned = SidebarCollectionEmptyPinnedLayoutState(
      headerHeight: 28,
      targetHeight: 56
    )
    let normalDestination = SidebarCollectionDragLayoutPlanner.plan(
      rows: rows,
      drag: DragState(
        sourceIDs: [.parent],
        destinationIndex: 3,
        slotHeight: 44
      ),
      emptyPinned: conditionalPinned
    )

    #expect(frame(normalDestination, .pinnedHeader)?.height == 28)
    #expect(frame(normalDestination, .pinGuide) == .init(minY: 28, height: 56))
    #expect(normalDestination.slotFrame == .init(minY: 112, height: 44))
    #expect(frame(normalDestination, .pinGuide) != normalDestination.slotFrame)
    #expect(frame(normalDestination, .contentHeader)?.minY == 84)
    #expect(frame(normalDestination, .next)?.minY == 156)

    let futureTeachingPresentation = SidebarCollectionDragLayoutPlanner.plan(
      rows: rows,
      drag: Optional<DragState>.none,
      emptyPinned: conditionalPinned
    )
    #expect(futureTeachingPresentation.slotFrame == nil)
    #expect(frame(futureTeachingPresentation, .pinnedHeader)?.height == 28)
    #expect(frame(futureTeachingPresentation, .pinGuide)?.height == 56)
    #expect(frame(futureTeachingPresentation, .contentHeader)?.minY == 84)
  }

  @Test("conditional section latches after crossing its entry threshold")
  func conditionalSectionLatchesForInteraction() {
    #expect(SidebarConditionalSectionResolver.resolve(
      position: 101,
      entryThreshold: 100,
      isActive: false,
      hysteresis: 4
    ) == false)
    #expect(SidebarConditionalSectionResolver.resolve(
      position: 96,
      entryThreshold: 100,
      isActive: false,
      hysteresis: 4
    ))
    #expect(SidebarConditionalSectionResolver.resolve(
      position: 1_000,
      entryThreshold: 100,
      isActive: true,
      hysteresis: 4
    ))
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
      emptyPinned: SidebarCollectionEmptyPinnedLayoutState(
        headerHeight: 28,
        targetHeight: 56
      )
    )
    #expect(emptyPinned[1] == 28)
    #expect(emptyPinned[2] == 84)
    #expect(emptyPinned[4] == 156)
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
