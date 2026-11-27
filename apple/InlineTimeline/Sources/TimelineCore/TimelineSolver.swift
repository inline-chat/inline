import CoreGraphics

/// Places rows around the viewport for a position. Pure: the only inputs it does not own are the
/// height of a row, asked for placed rows only, and where the span of the lowest visible row ends.
public enum TimelineSolver {
  public static func layout<ID: Hashable & Sendable>(
    rows: [ID],
    index: TimelineRowIndex<ID>,
    viewport: TimelineViewport,
    position: TimelinePosition<ID>,
    margins: TimelineMargins = .standard,
    allowsOverscroll: Bool = false,
    readingAnchor: TimelineReadingAnchor = .lowestVisible,
    spanEnd: (ID) -> ID? = { _ in nil },
    spanStart: (ID) -> ID? = { _ in nil },
    height: (ID) -> CGFloat
  ) -> TimelineLayout<ID> {
    guard !rows.isEmpty else { return .empty(viewport: viewport) }

    // The anchor row and its top.
    var isPinned = false
    let anchorIndex: Int
    let anchorTop: CGFloat
    switch position {
      case let .row(id, top):
        if let found = index[id] {
          anchorIndex = found
          anchorTop = top
        } else {
          anchorIndex = rows.count - 1
          anchorTop = viewport.usableBottom - height(rows[anchorIndex])
          isPinned = true
        }
      case .latest:
        anchorIndex = rows.count - 1
        anchorTop = viewport.usableBottom - height(rows[anchorIndex])
        isPinned = true
    }

    var restShift: CGFloat = 0
    var placements: [TimelinePlacement<ID>] = withoutActuallyEscaping(height) { height in
      var window = Window(rows: rows, viewport: viewport, margins: margins, height: height)
      window.start(at: anchorIndex, top: anchorTop)
      window.expand()
      if !allowsOverscroll {
        // A shift can bring new rows in, and new rows can change which limit applies.
        for _ in 0 ..< 4 {
          let shift = window.shiftIntoBounds()
          guard abs(shift) > 0.001 else { break }
          window.shift(by: shift)
          window.expand()
        }
      }
      restShift = window.shiftIntoBounds()
      return window.placements
    }
    // Drop rows wholly outside the margins, keeping at least one, and keeping the span of the lowest
    // visible row to its end (within `margins.span`), so the row holding what pins to it stays placed.
    // Only a span whose end is within reach is extended (measured first, so a longer one places nothing
    // extra): the rows it adds are rows that will show something.
    var keepThrough = -1
    if let visible = placements.last(where: { $0.y < viewport.usableBottom && $0.maxY > viewport.usableTop }),
       let end = spanEnd(visible.id), let endIndex = index[end], endIndex > visible.index,
       let last = placements.last, last.index < endIndex
    {
      var extra: [TimelinePlacement<ID>] = []
      var y = last.maxY
      var next = last.index + 1
      while next <= endIndex, y < viewport.height + margins.span {
        let rowHeight = max(0, height(rows[next]))
        extra.append(TimelinePlacement(id: rows[next], index: next, y: y, height: rowHeight))
        y += rowHeight
        next += 1
      }
      if next > endIndex {
        placements += extra
        keepThrough = endIndex
      }
    } else if let visible = placements.last(where: { $0.y < viewport.usableBottom && $0.maxY > viewport.usableTop }),
              let end = spanEnd(visible.id), let endIndex = index[end], endIndex > visible.index
    {
      // The end is already placed: keep it.
      keepThrough = endIndex
    }
    // The same for a span whose pin keeps to the top (held by its first row): the topmost visible row's span start
    // stays placed, so its pin is there while any of the span shows.
    var keepFrom = Int.max
    if let visible = placements.first(where: { $0.y < viewport.usableBottom && $0.maxY > viewport.usableTop }),
       let start = spanStart(visible.id), let startIndex = index[start], startIndex < visible.index, let first = placements.first
    {
      if first.index > startIndex {
        var extra: [TimelinePlacement<ID>] = []
        var y = first.y
        var previous = first.index - 1
        while previous >= startIndex, y > -margins.span {
          let rowHeight = max(0, height(rows[previous]))
          y -= rowHeight
          extra.append(TimelinePlacement(id: rows[previous], index: previous, y: y, height: rowHeight))
          previous -= 1
        }
        if previous < startIndex {
          placements = extra.reversed() + placements
          keepFrom = startIndex
        }
      } else {
        keepFrom = startIndex
      }
    }
    while placements.count > 1, placements[0].maxY < -margins.above, placements[0].index < keepFrom { placements.removeFirst() }
    while placements.count > 1, placements[placements.count - 1].y > viewport.height + margins.below,
          placements[placements.count - 1].index > keepThrough
    {
      placements.removeLast()
    }
    let first = placements[0]
    let last = placements[placements.count - 1]
    let reachesFirst = first.index == 0
    let reachesLast = last.index == rows.count - 1

    var resolved: TimelinePosition<ID> = position
    if isPinned, abs(restShift) <= 0.001 || allowsOverscroll {
      resolved = .latest
    } else if let visible = readingAnchor.row(in: placements, viewport: viewport) {
      // The reading row (by default the lowest visible one): what is newest on screen stays put when
      // rows above it arrive, leave or change height.
      resolved = .row(visible.id, top: visible.y)
    }

    return TimelineLayout(
      placements: placements,
      viewport: viewport,
      position: resolved,
      isAtBottom: reachesLast && last.maxY <= viewport.usableBottom + 0.5,
      distanceToOldest: reachesFirst ? max(0, viewport.usableTop - first.y) : nil,
      distanceToNewest: reachesLast ? max(0, last.maxY - viewport.usableBottom) : nil,
      restShift: restShift
    )
  }

  /// The contiguous run of placed rows while it is being built.
  private struct Window<ID: Hashable & Sendable> {
    let rows: [ID]
    let viewport: TimelineViewport
    let margins: TimelineMargins
    let height: (ID) -> CGFloat
    /// Rows above the anchor, nearest first; rows from the anchor down, in order.
    private var above: [TimelinePlacement<ID>] = []
    private var below: [TimelinePlacement<ID>] = []

    init(rows: [ID], viewport: TimelineViewport, margins: TimelineMargins, height: @escaping (ID) -> CGFloat) {
      self.rows = rows
      self.viewport = viewport
      self.margins = margins
      self.height = height
    }

    var first: TimelinePlacement<ID> { above.last ?? below[0] }
    var last: TimelinePlacement<ID> { below[below.count - 1] }
    var placements: [TimelinePlacement<ID>] { above.reversed() + below }

    mutating func start(at index: Int, top: CGFloat) {
      below = [TimelinePlacement(id: rows[index], index: index, y: top, height: max(0, height(rows[index])))]
    }

    mutating func expand() {
      while first.y > -margins.above, first.index > 0 {
        let index = first.index - 1
        let rowHeight = max(0, height(rows[index]))
        above.append(TimelinePlacement(id: rows[index], index: index, y: first.y - rowHeight, height: rowHeight))
      }
      while last.maxY < viewport.height + margins.below, last.index < rows.count - 1 {
        let index = last.index + 1
        let rowHeight = max(0, height(rows[index]))
        below.append(TimelinePlacement(id: rows[index], index: index, y: last.maxY, height: rowHeight))
      }
    }

    /// The shift that brings the content back inside its limits; zero when it is inside.
    /// Content shorter than the usable area rests on the usable bottom.
    func shiftIntoBounds() -> CGFloat {
      let reachesFirst = first.index == 0
      let reachesLast = last.index == rows.count - 1
      if reachesFirst, reachesLast, last.maxY - first.y <= viewport.usableHeight {
        return viewport.usableBottom - last.maxY
      }
      if reachesFirst, first.y > viewport.usableTop {
        return viewport.usableTop - first.y
      }
      if reachesLast, last.maxY < viewport.usableBottom {
        return viewport.usableBottom - last.maxY
      }
      return 0
    }

    mutating func shift(by delta: CGFloat) {
      for index in above.indices { above[index].y += delta }
      for index in below.indices { below[index].y += delta }
    }
  }
}

/// Which row a layout anchors on when it is not pinned: what stays put when rows above it change.
public enum TimelineReadingAnchor: Equatable, Sendable {
  /// The lowest row with any part above the usable bottom, a sliver included.
  case lowestVisible
  /// The lowest row showing at least `min(its height, points)` in the usable area.
  case lowestShowing(CGFloat)
  /// The lowest row showing at least half of itself.
  case lowestShowingHalf

  func row<ID: Hashable & Sendable>(in placements: [TimelinePlacement<ID>], viewport: TimelineViewport) -> TimelinePlacement<ID>? {
    let lowest = placements.last(where: { $0.y < viewport.usableBottom })
    func shown(_ p: TimelinePlacement<ID>) -> CGFloat {
      min(p.maxY, viewport.usableBottom) - max(p.y, viewport.usableTop)
    }
    switch self {
      case .lowestVisible:
        return lowest
      case let .lowestShowing(points):
        return placements.last(where: { $0.y < viewport.usableBottom && shown($0) >= min($0.height, points) - 0.5 }) ?? lowest
      case .lowestShowingHalf:
        return placements.last(where: { $0.y < viewport.usableBottom && shown($0) >= $0.height / 2 - 0.5 }) ?? lowest
    }
  }
}
