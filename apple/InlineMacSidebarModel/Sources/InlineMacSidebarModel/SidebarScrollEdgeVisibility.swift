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
  public let isProminentUnread: Bool

  public init(
    id: ID,
    minimumY: Double,
    maximumY: Double,
    isProminentUnread: Bool
  ) {
    self.id = id
    self.minimumY = minimumY
    self.maximumY = maximumY
    self.isProminentUnread = isProminentUnread
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
        countAbove += 1
        nearestAboveID = entry.id
      } else if entry.minimumY >= viewportEnd {
        countBelow += 1
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
