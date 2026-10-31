import CoreGraphics
import Foundation

/// Cell-independent sticky geometry. A date badge can follow the top of a
/// section; an avatar can follow the bottom of a sender group. The adapter
/// supplies native decoration views and content, never scroll compensation.
public struct ChatListDecoration<ID: Hashable & Sendable>: Sendable {
  public enum Edge: Sendable { case top, bottom }
  public let id: String
  public let firstRow: ID
  public let lastRow: ID
  public let edge: Edge
  public let x: CGFloat
  public let size: CGSize
  public let inset: CGFloat
  /// Stick to the viewport edge instead of the usable (inset) edge, like
  /// Telegram's `topEdge` headers that slide under a translucent bar.
  public let pinsToViewportEdge: Bool
  /// Fade out while stuck and the list is idle; reappear on scroll. Like
  /// Telegram's floating date header, it stays while within half its height of
  /// its natural position.
  public let hidesWhenIdle: Bool

  public init(
    id: String, firstRow: ID, lastRow: ID, edge: Edge,
    x: CGFloat, size: CGSize, inset: CGFloat = 0,
    pinsToViewportEdge: Bool = false, hidesWhenIdle: Bool = false
  ) {
    self.id = id
    self.firstRow = firstRow
    self.lastRow = lastRow
    self.edge = edge
    self.x = x
    self.size = size
    self.inset = inset
    self.pinsToViewportEdge = pinsToViewportEdge
    self.hidesWhenIdle = hidesWhenIdle
  }

  /// Evaluates from the *presented* row/child/inset/scroll sample, never targets.
  /// Returns viewport coordinates suitable for either host's overlay view.
  public func placement(in layout: TimelineLayout<ID>) -> ChatListDecorationPlacement? {
    guard x.isFinite, size.width.isFinite, size.height.isFinite, inset.isFinite,
          size.width > 0, size.height > 0,
          let first = layout.placement(for: firstRow),
          let last = layout.placement(for: lastRow),
          first.frame.minY <= last.frame.minY else { return nil }
    let lower = first.frame.minY
    let upper = max(lower, last.frame.maxY - size.height)
    let edgeRect = pinsToViewportEdge
      ? CGRect(x: 0, y: layout.originY, width: layout.viewport.width, height: layout.viewport.height)
      : layout.readingRect
    let desired: CGFloat
    let natural: CGFloat
    switch edge {
      case .top:
        desired = edgeRect.minY + inset
        natural = lower
      case .bottom:
        desired = edgeRect.maxY - size.height - inset
        natural = upper
    }
    let y = min(upper, max(lower, desired))
    let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    guard frame.intersects(pinsToViewportEdge ? edgeRect : layout.readingRect) else { return nil }
    return .init(id: id, frame: frame.offsetBy(dx: 0, dy: -layout.originY),
                 opacity: min(first.opacity, last.opacity),
                 isStuck: abs(y - natural) >= size.height / 2, stickDistance: abs(y - natural))
  }
}

public struct ChatListDecorationPlacement: Equatable, Sendable {
  public let id: String
  public let frame: CGRect
  public let opacity: CGFloat
  /// Held at the edge rather than at its natural row position.
  public let isStuck: Bool
  /// Distance from the natural position (Telegram's stick distance factor).
  public let stickDistance: CGFloat

  public init(id: String, frame: CGRect, opacity: CGFloat, isStuck: Bool = false, stickDistance: CGFloat = 0) {
    self.id = id
    self.frame = frame
    self.opacity = opacity
    self.isStuck = isStuck
    self.stickDistance = stickDistance
  }

  func withOpacity(_ value: CGFloat) -> Self {
    .init(id: id, frame: frame, opacity: value, isStuck: isStuck, stickDistance: stickDistance)
  }
}
