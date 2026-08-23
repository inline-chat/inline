public struct SidebarScrollEdgeVisibility: Equatable, Sendable {
  public let top: Bool
  public let bottom: Bool

  public init(top: Bool, bottom: Bool) {
    self.top = top
    self.bottom = bottom
  }

  public static func resolve(
    viewportStart: Double,
    viewportLength: Double,
    contentLength: Double,
    tolerance: Double = 0.5
  ) -> Self {
    let safeViewportLength = max(viewportLength, 0)
    let safeContentLength = max(contentLength, 0)
    let viewportEnd = viewportStart + safeViewportLength
    let hasSemanticOverflow = safeContentLength > safeViewportLength + tolerance
    return Self(
      top: hasSemanticOverflow && viewportStart > tolerance,
      bottom: hasSemanticOverflow && viewportEnd < safeContentLength - tolerance
    )
  }
}

public struct SidebarUnreadViewportEntry<ID: Hashable>: Equatable {
  public let id: ID
  public let minimumY: Double
  public let maximumY: Double
  public let prominentUnreadCount: Int

  public var isProminentUnread: Bool { prominentUnreadCount > 0 }

  public init(
    id: ID,
    minimumY: Double,
    maximumY: Double,
    isProminentUnread: Bool
  ) {
    self.id = id
    self.minimumY = minimumY
    self.maximumY = maximumY
    prominentUnreadCount = isProminentUnread ? 1 : 0
  }

  public init(
    id: ID,
    minimumY: Double,
    maximumY: Double,
    prominentUnreadCount: Int
  ) {
    self.id = id
    self.minimumY = minimumY
    self.maximumY = maximumY
    self.prominentUnreadCount = max(prominentUnreadCount, 0)
  }
}

extension SidebarUnreadViewportEntry: Sendable where ID: Sendable {}

public struct SidebarUnreadViewportDirection<ID: Hashable>: Equatable {
  public let count: Int
  public let targetID: ID

  public init(count: Int, targetID: ID) {
    self.count = count
    self.targetID = targetID
  }
}

extension SidebarUnreadViewportDirection: Sendable where ID: Sendable {}

public struct SidebarUnreadViewportResolution<ID: Hashable>: Equatable {
  public let above: SidebarUnreadViewportDirection<ID>?
  public let below: SidebarUnreadViewportDirection<ID>?

  public init(
    above: SidebarUnreadViewportDirection<ID>?,
    below: SidebarUnreadViewportDirection<ID>?
  ) {
    self.above = above
    self.below = below
  }
}

extension SidebarUnreadViewportResolution: Sendable where ID: Sendable {}

/// Converts an unread row's layout bounds into one bounded programmatic scroll.
/// Distant targets begin one viewport away so only the final approach animates,
/// matching Telegram's long-distance list navigation without traversing every row.
public struct SidebarUnreadScrollPlan: Equatable, Sendable {
  public let targetOffset: Double
  public let animatedStartOffset: Double
  public let usesLongDistanceJump: Bool

  public static func resolve(
    currentOffset: Double,
    targetMinimum: Double,
    targetMaximum: Double,
    viewportLength: Double,
    contentLength: Double
  ) -> Self {
    let safeViewportLength = max(viewportLength, 0)
    let maximumOffset = max(contentLength - safeViewportLength, 0)
    let currentOffset = min(max(currentOffset, 0), maximumOffset)
    let targetMiddle =
      (min(targetMinimum, targetMaximum) + max(targetMinimum, targetMaximum)) / 2
    let targetOffset = min(
      max(targetMiddle - safeViewportLength / 2, 0),
      maximumOffset
    )
    let delta = targetOffset - currentOffset
    let usesLongDistanceJump =
      safeViewportLength > 0
      && abs(delta) > safeViewportLength
    let animatedStartOffset =
      usesLongDistanceJump
      ? targetOffset - (delta > 0 ? safeViewportLength : -safeViewportLength)
      : currentOffset

    return Self(
      targetOffset: targetOffset,
      animatedStartOffset: min(max(animatedStartOffset, 0), maximumOffset),
      usesLongDistanceJump: usesLongDistanceJump
    )
  }
}

/// Resolves only the two compact unread affordances needed by the viewport.
/// Keeping this projection native prevents scroll position from invalidating
/// the complete SwiftUI sidebar hierarchy.
public enum SidebarUnreadViewportResolver {
  public static func resolve<ID: Hashable>(
    entries: [SidebarUnreadViewportEntry<ID>],
    viewportStart: Double,
    viewportLength: Double
  ) -> SidebarUnreadViewportResolution<ID> {
    let viewportEnd = viewportStart + max(viewportLength, 0)
    var countAbove = 0
    var nearestAboveID: ID?
    var countBelow = 0
    var nearestBelowID: ID?

    for entry in entries where entry.isProminentUnread {
      if entry.maximumY <= viewportStart {
        countAbove += entry.prominentUnreadCount
        nearestAboveID = entry.id
      } else if entry.minimumY >= viewportEnd {
        countBelow += entry.prominentUnreadCount
        nearestBelowID = nearestBelowID ?? entry.id
      }
    }

    return SidebarUnreadViewportResolution(
      above: nearestAboveID.map {
        SidebarUnreadViewportDirection(count: countAbove, targetID: $0)
      },
      below: nearestBelowID.map {
        SidebarUnreadViewportDirection(count: countBelow, targetID: $0)
      }
    )
  }
}
