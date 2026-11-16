import CoreGraphics

/// Where an update wants the reader to be.
public enum TimelineScroll<ID: Hashable & Sendable>: Equatable, Sendable {
  /// Keep what the reader sees: pinned stays pinned, a reading row stays where it is.
  case preserve
  /// Pin to the newest row.
  case latest
  /// Move the content by this many points (positive: content moves down, towards older rows).
  case by(CGFloat)
  /// Put this row at a place in the usable area.
  case to(ID, TimelineAlignment)
}

public enum TimelineAlignment: Equatable, Sendable {
  /// The row's top this far below the usable top.
  case top(CGFloat)
  /// The row centred in the usable area (its top at the usable top when taller than the area).
  case center
  /// The row's bottom this far above the usable bottom.
  case bottom(CGFloat)
}

/// Everything that can change, in one value. Every source of change (data, keyboard, composer,
/// rotation, scrolling, jumps) is one of these, so they are resolved together and cannot disagree.
public struct TimelineUpdate<ID: Hashable & Sendable>: Sendable {
  /// The new ordered rows, oldest first; nil keeps the current ones.
  public var rows: [ID]?
  public var coverage: TimelineCoverage?
  public var viewport: TimelineViewport?
  public var scroll: TimelineScroll<ID>
  /// A reading row follows the usable bottom, as content does when a keyboard opens. False while
  /// a finger holds the list: then the content under the finger stays where it is.
  public var followsBottomInset: Bool
  /// Pin when the reader was resting on the newest row before this update. False while a finger
  /// holds the list.
  public var pinsWhenAtBottom: Bool
  /// Let the content leave its limits (rubber band).
  public var allowsOverscroll: Bool

  public init(
    rows: [ID]? = nil, coverage: TimelineCoverage? = nil, viewport: TimelineViewport? = nil,
    scroll: TimelineScroll<ID> = .preserve, followsBottomInset: Bool = true, pinsWhenAtBottom: Bool = true,
    allowsOverscroll: Bool = false
  ) {
    self.rows = rows
    self.coverage = coverage
    self.viewport = viewport
    self.scroll = scroll
    self.followsBottomInset = followsBottomInset
    self.pinsWhenAtBottom = pinsWhenAtBottom
    self.allowsOverscroll = allowsOverscroll
  }
}

public enum TimelineEdge: Hashable, Sendable {
  case older
  case newer
}

/// What one update did, as data. The settled layout is final at once; `offsets` say where each
/// placed row should appear to start from, so a host can add one additive animation per row (or one
/// for the whole content when `uniformOffset` is set) with the update's timing.
public struct TimelineChange<ID: Hashable & Sendable>: Sendable {
  public var layout: TimelineLayout<ID>
  public var previous: TimelineLayout<ID>
  /// For every placed row, old y minus settled y. A row that was not placed before travels with its
  /// nearest placed neighbour, so a block of rows moves rigidly.
  public var offsets: [ID: CGFloat]
  /// Set when every placed row has the same non-zero offset.
  public var uniformOffset: CGFloat?
  /// Placed rows whose height changed, with the old height.
  public var previousHeights: [ID: CGFloat]
  /// Rows new to the data that are placed now.
  public var inserted: Set<ID>
  /// Rows that left the data while placed, at their last frames.
  public var removed: [TimelinePlacement<ID>]
  /// No row placed before is placed now: a jump to another part of the chat.
  public var isDisjoint: Bool
  /// Loaded ends the window is close to that are not real ends.
  public var demands: Set<TimelineEdge>

  public var movesAnything: Bool {
    offsets.values.contains { abs($0) > 0.001 } || !previousHeights.isEmpty || !inserted.isEmpty || !removed.isEmpty
  }
}

/// The timeline's state and its single way to change.
public struct TimelineState<ID: Hashable & Sendable>: Sendable {
  public private(set) var rows: [ID] = []
  public private(set) var index: [ID: Int] = [:]
  public private(set) var coverage = TimelineCoverage()
  public private(set) var layout: TimelineLayout<ID>
  public var margins: TimelineMargins
  /// Rows from a loaded end at which more history is asked for.
  public var demandThreshold = 12

  public init(viewport: TimelineViewport, margins: TimelineMargins = .standard) {
    layout = .empty(viewport: viewport)
    self.margins = margins
  }

  public var viewport: TimelineViewport { layout.viewport }
  public var position: TimelinePosition<ID> { layout.position }

  @discardableResult
  public mutating func apply(
    _ update: TimelineUpdate<ID>, spanEnd: (ID) -> ID? = { _ in nil }, height: (ID) -> CGFloat
  ) -> TimelineChange<ID> {
    let previous = layout
    let previousIndex = index
    var position = previous.position

    if let newRows = update.rows {
      rows = newRows
      index = Dictionary(uniqueKeysWithValues: newRows.enumerated().map { ($0.element, $0.offset) })
      position = Self.survivingPosition(position, previous: previous, index: index)
    }
    if let newCoverage = update.coverage { coverage = newCoverage }

    // Resting on the newest row counts as pinned, so arrivals and growth keep the bottom.
    if update.pinsWhenAtBottom, update.scroll == .preserve, previous.isAtBottom, !previous.placements.isEmpty {
      position = .latest
    }

    let viewport = update.viewport ?? previous.viewport
    if case let .row(id, top) = position, update.followsBottomInset {
      // A reading row keeps its distance from the usable bottom: it follows the keyboard, the
      // composer and a change of the view's height.
      position = .row(id, top: top + (viewport.usableBottom - previous.viewport.usableBottom))
    }

    switch update.scroll {
      case .preserve:
        break
      case .latest:
        position = .latest
      case let .by(delta):
        switch position {
          case let .row(id, top):
            position = .row(id, top: top + delta)
          case .latest:
            if let last = previous.placements.last, index[last.id] != nil {
              position = .row(last.id, top: last.y + delta)
            }
        }
      case let .to(id, alignment):
        if index[id] != nil {
          let rowHeight = height(id)
          let top: CGFloat = switch alignment {
            case let .top(distance): viewport.usableTop + distance
            case .center: viewport.usableTop + max(0, (viewport.usableHeight - rowHeight) / 2)
            case let .bottom(distance): viewport.usableBottom - distance - rowHeight
          }
          position = .row(id, top: top)
        }
    }

    layout = TimelineSolver.layout(
      rows: rows, index: index, viewport: viewport, position: position, margins: margins,
      allowsOverscroll: update.allowsOverscroll, spanEnd: spanEnd, height: height
    )
    return Self.change(from: previous, previousIndex: previousIndex, to: layout, index: index, coverage: coverage,
                       demandThreshold: demandThreshold)
  }

  /// A reading row that left the data hands its place to the nearest placed row that stayed:
  /// newer rows first, then older ones.
  private static func survivingPosition(
    _ position: TimelinePosition<ID>, previous: TimelineLayout<ID>, index: [ID: Int]
  ) -> TimelinePosition<ID> {
    guard case let .row(id, _) = position, index[id] == nil else { return position }
    let placements = previous.placements
    guard let at = placements.firstIndex(where: { $0.id == id }) else { return .latest }
    if let newer = placements[(at + 1)...].first(where: { index[$0.id] != nil }) {
      return .row(newer.id, top: newer.y)
    }
    if let older = placements[..<at].last(where: { index[$0.id] != nil }) {
      return .row(older.id, top: older.y)
    }
    return .latest
  }

  private static func change(
    from previous: TimelineLayout<ID>, previousIndex: [ID: Int], to layout: TimelineLayout<ID>, index: [ID: Int],
    coverage: TimelineCoverage, demandThreshold: Int
  ) -> TimelineChange<ID> {
    var oldByID: [ID: TimelinePlacement<ID>] = [:]
    oldByID.reserveCapacity(previous.placements.count)
    for placement in previous.placements { oldByID[placement.id] = placement }

    var offsets: [ID: CGFloat] = [:]
    offsets.reserveCapacity(layout.placements.count)
    var previousHeights: [ID: CGFloat] = [:]
    var inserted: Set<ID> = []
    var survivors = 0

    // Survivors move by their own distance.
    var known: [CGFloat?] = []
    known.reserveCapacity(layout.placements.count)
    for placement in layout.placements {
      if let old = oldByID[placement.id] {
        survivors += 1
        known.append(old.y - placement.y)
        if abs(old.height - placement.height) > 0.001 { previousHeights[placement.id] = old.height }
      } else {
        known.append(nil)
        if previousIndex[placement.id] == nil { inserted.insert(placement.id) }
      }
    }
    // Rows placed for the first time travel with the nearest survivor: the one above, or the
    // first one below for rows above every survivor.
    var carried: CGFloat?
    for position in known.indices {
      if let value = known[position] { carried = value } else if let carried { known[position] = carried }
    }
    carried = nil
    for position in known.indices.reversed() {
      if let value = known[position] { carried = value } else if let carried { known[position] = carried }
    }
    for (position, placement) in layout.placements.enumerated() {
      offsets[placement.id] = known[position] ?? 0
    }

    var uniformOffset: CGFloat?
    if let first = layout.placements.first.flatMap({ offsets[$0.id] }), abs(first) > 0.001,
       offsets.values.allSatisfy({ abs($0 - first) <= 0.001 })
    {
      uniformOffset = first
    }

    let removed = previous.placements.filter { index[$0.id] == nil }

    var demands: Set<TimelineEdge> = []
    if let first = layout.placements.first, let last = layout.placements.last {
      if !coverage.reachesOldest, first.index < demandThreshold { demands.insert(.older) }
      if !coverage.reachesNewest, index.count - 1 - last.index < demandThreshold { demands.insert(.newer) }
    }

    return TimelineChange(
      layout: layout, previous: previous, offsets: offsets, uniformOffset: uniformOffset,
      previousHeights: previousHeights, inserted: inserted, removed: removed,
      isDisjoint: survivors == 0 && !previous.placements.isEmpty && !layout.placements.isEmpty,
      demands: demands
    )
  }
}
