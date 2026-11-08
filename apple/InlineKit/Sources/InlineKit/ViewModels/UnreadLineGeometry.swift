import Foundation

/// Where the unread line sits on screen, in a top-down list whose scroll origin is the top of
/// the clip view and whose insets let the origin run from `-topInset` to
/// `documentHeight + bottomInset - viewportHeight`, as AppKit's `NSScrollView.contentInsets`.
///
/// Like Telegram's unread landing and ChatList's reading intent, the origin is derived from the
/// line's row on every pass: `lineTop - topInset - hold`, clamped to the scroll range. Clamping
/// never drops the hold; only the user or an explicit scroll does.
public struct UnreadLineGeometry: Equatable, Sendable {
  /// Top of the unread line's row in document coordinates.
  public var lineTop: CGFloat
  public var documentHeight: CGFloat
  /// Height of the clip view, including the areas under the insets.
  public var viewportHeight: CGFloat
  public var topInset: CGFloat
  public var bottomInset: CGFloat

  public init(
    lineTop: CGFloat,
    documentHeight: CGFloat,
    viewportHeight: CGFloat,
    topInset: CGFloat,
    bottomInset: CGFloat
  ) {
    self.lineTop = lineTop
    self.documentHeight = documentHeight
    self.viewportHeight = viewportHeight
    self.topInset = topInset
    self.bottomInset = bottomInset
  }

  public var scrollRange: ClosedRange<CGFloat> {
    let lower = -topInset
    return lower ... max(lower, documentHeight + bottomInset - viewportHeight)
  }

  /// The origin a chat opens at with the line at the top, or nil when the rows from the line
  /// down fit on screen; the chat then opens at its bottom, holding nothing, as Telegram's
  /// landing clamped at the newest edge.
  public var landingOrigin: CGFloat? {
    let range = scrollRange
    let target = lineTop - topInset
    guard target < range.upperBound - Self.tolerance else { return nil }
    return max(range.lowerBound, target)
  }

  /// The origin that keeps a held line `hold` points below the top inset.
  public func heldOrigin(hold: CGFloat) -> CGFloat {
    let range = scrollRange
    return min(range.upperBound, max(range.lowerBound, lineTop - topInset - hold))
  }

  /// Corrections smaller than this are not applied, so equal geometry never scrolls.
  public static let tolerance: CGFloat = 0.5
}
