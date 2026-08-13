/// Semantic role needed by the value-only vertical drag planner. Product row
/// content remains owned by the platform presentation layer.
public enum SidebarCollectionDragLayoutRowRole: Hashable, Sendable {
  case ordinary
  case pinnedHeader
  case emptyPinnedGuide
}

public struct SidebarCollectionDragLayoutRow<RowID: Hashable>: Hashable {
  public let id: RowID
  public let height: Double
  public let role: SidebarCollectionDragLayoutRowRole

  public init(
    id: RowID,
    height: Double,
    role: SidebarCollectionDragLayoutRowRole = .ordinary
  ) {
    self.id = id
    self.height = height
    self.role = role
  }
}

extension SidebarCollectionDragLayoutRow: Sendable where RowID: Sendable {}

/// The only mutable geometry input during an internal drag: one frozen source
/// group and one stable semantic destination index.
public struct SidebarCollectionDragLayoutState<RowID: Hashable>: Hashable {
  public let sourceIDs: Set<RowID>
  public let destinationIndex: Int
  public let slotHeight: Double
  public let hidesPinnedHeader: Bool

  public init(
    sourceIDs: Set<RowID>,
    destinationIndex: Int,
    slotHeight: Double,
    hidesPinnedHeader: Bool = false
  ) {
    self.sourceIDs = sourceIDs
    self.destinationIndex = destinationIndex
    self.slotHeight = slotHeight
    self.hidesPinnedHeader = hidesPinnedHeader
  }
}

extension SidebarCollectionDragLayoutState: Sendable where RowID: Sendable {}

/// Conditional empty-Pinned presentation is document geometry controlled by
/// the caller. When active, the target owns the one slot at a Pinned
/// destination and remains ordinary instructional geometry elsewhere. This
/// also supports a future teaching presentation without an active drag.
public struct SidebarCollectionEmptyPinnedLayoutState: Hashable, Sendable {
  public let headerHeight: Double
  public let targetHeight: Double

  public init(headerHeight: Double, targetHeight: Double) {
    self.headerHeight = headerHeight
    self.targetHeight = targetHeight
  }
}

/// Resolves a conditional section against frozen drag-start geometry. Once
/// entered, the section remains active until its owning interaction ends so
/// the destination cannot move away while the user is trying to land a drop.
public enum SidebarConditionalSectionResolver {
  public static func resolve(
    position: Double,
    entryThreshold: Double,
    isActive: Bool,
    hysteresis: Double = 0
  ) -> Bool {
    guard isActive == false else { return true }
    let hysteresis = max(hysteresis, 0)
    return position <= entryThreshold - hysteresis
  }
}

public struct SidebarCollectionVerticalFrame: Hashable, Sendable {
  public let minY: Double
  public let height: Double

  public init(minY: Double, height: Double) {
    self.minY = minY
    self.height = height
  }

  public var maxY: Double { minY + height }
}

public struct SidebarCollectionDragLayoutResult<RowID: Hashable> {
  public let rowFrames: [RowID: SidebarCollectionVerticalFrame]
  public let visibleRowIDs: Set<RowID>
  public let slotFrame: SidebarCollectionVerticalFrame?
  public let contentHeight: Double

  public init(
    rowFrames: [RowID: SidebarCollectionVerticalFrame],
    visibleRowIDs: Set<RowID>,
    slotFrame: SidebarCollectionVerticalFrame?,
    contentHeight: Double
  ) {
    self.rowFrames = rowFrames
    self.visibleRowIDs = visibleRowIDs
    self.slotFrame = slotFrame
    self.contentHeight = contentHeight
  }
}

extension SidebarCollectionDragLayoutResult: Sendable where RowID: Sendable {}

/// Binary stable-slot resolver for a geometry scene whose guide positions are
/// frozen and sorted at drag start. The current index owns ties and hysteresis,
/// so a stationary pointer cannot alternate between neighboring slots.
public enum SidebarCollectionSortedPositionResolver {
  public static func resolve(
    position: Double,
    sortedPositions: [Double],
    currentIndex: Int?,
    hysteresis: Double = 0
  ) -> Int? {
    guard sortedPositions.isEmpty == false else { return nil }

    var lower = 0
    var upper = sortedPositions.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if sortedPositions[middle] < position {
        lower = middle + 1
      } else {
        upper = middle
      }
    }

    let neighbors = [lower - 1, lower].filter { sortedPositions.indices.contains($0) }
    var bestIndex = neighbors[0]
    var bestDistance = abs(position - sortedPositions[bestIndex])
    for index in neighbors.dropFirst() {
      let distance = abs(position - sortedPositions[index])
      if distance < bestDistance || (distance == bestDistance && index == currentIndex) {
        bestIndex = index
        bestDistance = distance
      }
    }

    guard let currentIndex,
          sortedPositions.indices.contains(currentIndex),
          currentIndex != bestIndex
    else { return bestIndex }
    let currentDistance = abs(position - sortedPositions[currentIndex])
    return bestDistance + max(hysteresis, 0) >= currentDistance
      ? currentIndex
      : bestIndex
  }
}

/// Produces deterministic one-dimensional collection geometry from a frozen
/// row scene. The source never reserves space; exactly one destination does.
public enum SidebarCollectionDragLayoutPlanner {
  /// Returns the leading edge for every insertion index in the source-removed
  /// scene. Callers can build all semantic drag proposals in one linear pass
  /// instead of cloning the complete row layout once per possible slot.
  public static func slotPositions<RowID: Hashable>(
    rows: [SidebarCollectionDragLayoutRow<RowID>],
    sourceIDs: Set<RowID>,
    emptyPinned: SidebarCollectionEmptyPinnedLayoutState? = nil,
    hidesPinnedHeader: Bool = false
  ) -> [Int: Double] {
    var positions: [Int: Double] = [:]
    var y = 0.0
    var reducedIndex = 0

    for row in rows {
      guard sourceIDs.contains(row.id) == false else { continue }
      positions[reducedIndex] = y

      switch row.role {
      case .pinnedHeader:
        if let emptyPinned {
          y += max(emptyPinned.headerHeight, 0)
        } else if hidesPinnedHeader == false {
          y += max(row.height, 0)
        }
      case .emptyPinnedGuide:
        if let emptyPinned {
          y += max(emptyPinned.targetHeight, 0)
        }
      case .ordinary:
        y += max(row.height, 0)
      }
      reducedIndex += 1
    }

    positions[reducedIndex] = y
    return positions
  }

  public static func plan<RowID: Hashable>(
    rows: [SidebarCollectionDragLayoutRow<RowID>],
    drag: SidebarCollectionDragLayoutState<RowID>?,
    emptyPinned: SidebarCollectionEmptyPinnedLayoutState? = nil
  ) -> SidebarCollectionDragLayoutResult<RowID> {
    var frames: [RowID: SidebarCollectionVerticalFrame] = [:]
    var visibleIDs = Set<RowID>()
    var slotFrame: SidebarCollectionVerticalFrame?
    var y = 0.0
    var reducedIndex = 0
    var insertedSlot = false

    func insertSlotIfNeeded() {
      guard insertedSlot == false,
            let drag,
            reducedIndex == drag.destinationIndex
      else { return }
      let frame = SidebarCollectionVerticalFrame(
        minY: y,
        height: max(drag.slotHeight, 0)
      )
      slotFrame = frame
      y = frame.maxY
      insertedSlot = true
    }

    for row in rows {
      if row.role == .pinnedHeader {
        let height: Double
        if let emptyPinned {
          height = max(emptyPinned.headerHeight, 0)
        } else if drag?.hidesPinnedHeader == true {
          height = 0
        } else {
          height = max(row.height, 0)
        }
        frames[row.id] = SidebarCollectionVerticalFrame(minY: y, height: height)
        if height > 0 {
          visibleIDs.insert(row.id)
          y += height
        }
        reducedIndex += 1
        continue
      }

      if row.role == .emptyPinnedGuide, let emptyPinned {
        let frame = SidebarCollectionVerticalFrame(
          minY: y,
          height: max(emptyPinned.targetHeight, 0)
        )
        frames[row.id] = frame
        visibleIDs.insert(row.id)
        y = frame.maxY
        if let drag, reducedIndex == drag.destinationIndex {
          slotFrame = frame
          insertedSlot = true
        }
        reducedIndex += 1
        continue
      }

      let height = max(row.height, 0)
      if height == 0 {
        frames[row.id] = SidebarCollectionVerticalFrame(minY: y, height: 0)
        reducedIndex += 1
        continue
      }

      if drag?.sourceIDs.contains(row.id) == true {
        frames[row.id] = SidebarCollectionVerticalFrame(minY: y, height: height)
        continue
      }

      insertSlotIfNeeded()
      frames[row.id] = SidebarCollectionVerticalFrame(minY: y, height: height)
      visibleIDs.insert(row.id)
      y += height
      reducedIndex += 1
    }

    insertSlotIfNeeded()
    if let drag, insertedSlot == false {
      let frame = SidebarCollectionVerticalFrame(
        minY: y,
        height: max(drag.slotHeight, 0)
      )
      slotFrame = frame
      y = frame.maxY
    }

    return SidebarCollectionDragLayoutResult(
      rowFrames: frames,
      visibleRowIDs: visibleIDs,
      slotFrame: slotFrame,
      contentHeight: y
    )
  }
}
