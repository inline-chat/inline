import CoreGraphics

// The timeline has no global content height. Its state is an ordered list of row ids, oldest first,
// and a position: either pinned to the newest row, or one row held at a distance from the viewport's
// top. Only rows near the viewport are placed, and only placed rows have heights. Nothing is
// estimated, so nothing is corrected later.
//
// Coordinates: y grows downward from the viewport's top edge (the list view's bounds, origin zero).

/// The list view's size and what covers it.
public struct TimelineViewport: Equatable, Sendable {
  public var width: CGFloat
  public var height: CGFloat
  /// Covered at the top: bars, a pinned header.
  public var topInset: CGFloat
  /// Covered at the bottom: the composer and whatever keyboard is over the list.
  public var bottomInset: CGFloat

  public init(width: CGFloat, height: CGFloat, topInset: CGFloat = 0, bottomInset: CGFloat = 0) {
    self.width = width
    self.height = height
    self.topInset = topInset
    self.bottomInset = bottomInset
  }

  /// The first y a row may show at.
  public var usableTop: CGFloat { topInset }
  /// The y the newest row's bottom rests on.
  public var usableBottom: CGFloat { height - bottomInset }
  public var usableHeight: CGFloat { max(0, usableBottom - usableTop) }
}

/// Whether the loaded rows reach the real ends of the chat. A loaded end that is not a real end
/// still limits scrolling; it also raises a demand for more history.
public struct TimelineCoverage: Equatable, Sendable {
  public var reachesOldest: Bool
  public var reachesNewest: Bool

  public init(reachesOldest: Bool = true, reachesNewest: Bool = true) {
    self.reachesOldest = reachesOldest
    self.reachesNewest = reachesNewest
  }
}

/// Where the reader is.
public enum TimelinePosition<ID: Hashable & Sendable>: Equatable, Sendable {
  /// Pinned: the newest row's bottom rests on the usable bottom, whatever arrives or grows.
  case latest
  /// This row's top is `top` points below the viewport's top edge. Layouts report the lowest
  /// visible row here.
  case row(ID, top: CGFloat)
}

/// One placed row.
public struct TimelinePlacement<ID: Hashable & Sendable>: Equatable, Sendable {
  public let id: ID
  /// Index in the row list this layout was made from.
  public let index: Int
  public var y: CGFloat
  public var height: CGFloat

  public var maxY: CGFloat { y + height }
}

/// The settled placement of the rows around the viewport.
public struct TimelineLayout<ID: Hashable & Sendable>: Equatable, Sendable {
  /// Contiguous rows, oldest first, top to bottom.
  public var placements: [TimelinePlacement<ID>]
  public var viewport: TimelineViewport
  /// The position this layout realises, expressed on a visible row (or `.latest`).
  public var position: TimelinePosition<ID>
  /// The newest loaded row's bottom is on (or above) the usable bottom.
  public var isAtBottom: Bool
  /// How much further the content can travel down (towards older rows) before the oldest loaded
  /// row's top reaches the usable top. Nil while the oldest loaded row is not placed.
  public var distanceToOldest: CGFloat?
  /// How much further the content can travel up before the newest loaded row's bottom reaches the
  /// usable bottom. Nil while the newest loaded row is not placed.
  public var distanceToNewest: CGFloat?
  /// The shift that would bring the content back inside its limits: zero at rest, non-zero only
  /// while overscrolled (positive: the content has to move down).
  public var restShift: CGFloat

  public static func empty(viewport: TimelineViewport) -> TimelineLayout {
    TimelineLayout(
      placements: [], viewport: viewport, position: .latest, isAtBottom: true,
      distanceToOldest: 0, distanceToNewest: 0, restShift: 0
    )
  }

  public func placement(for id: ID) -> TimelinePlacement<ID>? {
    placements.first { $0.id == id }
  }

  /// Rows that intersect the usable area.
  public var visible: ArraySlice<TimelinePlacement<ID>> {
    guard let first = placements.firstIndex(where: { $0.maxY > viewport.usableTop }) else { return [] }
    let end = placements[first...].firstIndex(where: { $0.y >= viewport.usableBottom }) ?? placements.endIndex
    return placements[first ..< end]
  }
}

/// How far beyond the viewport rows are kept placed.
public struct TimelineMargins: Equatable, Sendable {
  public var above: CGFloat
  public var below: CGFloat
  /// How far below the view the span of the lowest visible row is still placed to its end, so what
  /// pins to that end (a sender's avatar) is there while any of the span is in sight. A span ending
  /// farther away places nothing extra. About a screen, so the rows it adds at once stay few.
  public var span: CGFloat

  public init(above: CGFloat, below: CGFloat, span: CGFloat = 900) {
    self.above = above
    self.below = below
    self.span = span
  }

  public static let standard = TimelineMargins(above: 200, below: 200)
}

/// The timing every part of one update moves with. The host turns it into Core Animation.
public enum TimelineTiming: Equatable, Sendable {
  case none
  case spring(mass: CGFloat, stiffness: CGFloat, damping: CGFloat, duration: CGFloat)
  case curve(duration: CGFloat, c1x: Float, c1y: Float, c2x: Float, c2y: Float)

  /// The system keyboard on iOS 26 and later.
  public static let keyboard = TimelineTiming.spring(mass: 1, stiffness: 555.027, damping: 47.118, duration: 0.3832)
  /// The keyboard before iOS 26.
  public static let legacyKeyboard = TimelineTiming.spring(mass: 3, stiffness: 1000, damping: 500, duration: 0.5)
  /// Rows arriving, leaving and changing height.
  public static let standard = TimelineTiming.spring(mass: 1, stiffness: 555.027, damping: 47.118, duration: 0.3832)
  /// A streamed message growing by a line.
  public static let streamingLine = TimelineTiming.curve(duration: 0.15, c1x: 0.42, c1y: 0, c2x: 0.58, c2y: 1)

  public var isAnimated: Bool { self != .none }
}
