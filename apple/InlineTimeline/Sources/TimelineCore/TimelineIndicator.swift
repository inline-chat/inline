import CoreGraphics

/// The scroll indicator of a list with no global content height.
///
/// Only the placed rows have heights and only the loaded rows are known at all, so the content's
/// extent beyond the placed rows is an estimate that changes when rows are measured, when a page of
/// history arrives, or when the window moves. A thumb drawn from that estimate directly would jump
/// on each of those. Instead the thumb's place (`progress`) is state: it only moves when the content
/// moves, and then towards the end the content is moving to, by the share of the estimated distance
/// to that end the move covers. So it never moves against the scroll, it reaches an end exactly when
/// the content does, and a change in the estimate shows as a change of pace rather than a jump.
/// It is set from the estimate outright only when the list jumps somewhere (opening, a far jump).
public struct TimelineIndicator: Equatable, Sendable {
  /// What the indicator knows about the content around the usable area.
  public struct Extent: Equatable, Sendable {
    /// How much further the content can travel down (towards older rows), estimated.
    public var above: CGFloat
    /// How much further the content can travel up (towards newer rows), estimated.
    public var below: CGFloat
    /// The usable area's height: what the thumb's length stands for.
    public var visible: CGFloat

    public init(above: CGFloat, below: CGFloat, visible: CGFloat) {
      self.above = max(0, above)
      self.below = max(0, below)
      self.visible = max(0, visible)
    }

    /// The whole estimated content.
    public var total: CGFloat { above + visible + below }
    /// Nothing to scroll: the indicator has nothing to show.
    public var isScrollable: Bool { above + below > 0.5 }
  }

  /// The thumb's place on its track: 0 at the top (the oldest end), 1 at the bottom (the newest).
  public var progress: CGFloat

  public init(progress: CGFloat) {
    self.progress = min(1, max(0, progress))
  }

  /// The place the extent alone suggests.
  public static func estimate(_ extent: Extent) -> CGFloat {
    let travel = extent.above + extent.below
    guard travel > 0 else { return 1 }
    return extent.above / travel
  }

  /// The place after the content moved by `delta` from where `extent` was measured (positive: down,
  /// towards older rows, as `TimelineScroll.by`). Linear in `delta` on each side of zero, so a
  /// path of scroll positions maps to a path of thumb places sample by sample.
  public static func progress(_ progress: CGFloat, extent: Extent, moved delta: CGFloat) -> CGFloat {
    if delta > 0 {
      // Towards the top: the thumb covers the same share of its way there as the content does.
      guard extent.above > 0 else { return 0 }
      return progress * max(0, extent.above - delta) / extent.above
    } else if delta < 0 {
      guard extent.below > 0 else { return 1 }
      return 1 - (1 - progress) * max(0, extent.below + delta) / extent.below
    }
    return progress
  }

  /// Moves the thumb with the content.
  public mutating func move(by delta: CGFloat, extent: Extent) {
    progress = Self.progress(progress, extent: extent, moved: delta)
  }

  /// The thumb's length on a track of this length, UIScrollView's proportion of the visible content.
  public static func length(_ extent: Extent, track: CGFloat, minimum: CGFloat) -> CGFloat {
    let total = extent.total
    guard total > 0, track > 0 else { return 0 }
    return min(track, max(minimum, (track * extent.visible / total).rounded()))
  }
}

extension TimelineLayout {
  /// The indicator's extent for this layout of `rowCount` rows: exact where an end is placed, the
  /// placed rows' mean height for each row beyond, plus `unknown` beyond an end the loaded rows do not
  /// reach (more history may be there), so the thumb meets its end only at a real end.
  public func indicatorExtent(rowCount: Int, coverage: TimelineCoverage, unknown: CGFloat) -> TimelineIndicator.Extent {
    guard let first = placements.first, let last = placements.last else {
      return TimelineIndicator.Extent(above: 0, below: 0, visible: viewport.usableHeight)
    }
    let placedHeight = last.maxY - first.y
    let mean = placedHeight / CGFloat(placements.count)
    var above = distanceToOldest ?? (viewport.usableTop - first.y + CGFloat(first.index) * mean)
    var below = distanceToNewest ?? (last.maxY - viewport.usableBottom + CGFloat(rowCount - 1 - last.index) * mean)
    if !coverage.reachesOldest { above += unknown }
    if !coverage.reachesNewest { below += unknown }
    return TimelineIndicator.Extent(above: above, below: below, visible: viewport.usableHeight)
  }
}
