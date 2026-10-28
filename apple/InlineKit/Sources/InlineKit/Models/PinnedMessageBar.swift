import Foundation

/// Which pin the chat header shows when a chat has several, following Telegram.
///
/// Pins are kept in chat order (oldest first). The header starts on the newest pin. Tapping jumps to the
/// shown pin and moves the header to the next older one; after the oldest it wraps to the newest.
/// A newly pinned message is shown right away, and when the shown pin is unpinned the header falls back
/// to the nearest older pin.
public struct PinnedMessageBar: Equatable, Sendable {
  public static let maxVisibleStripeSegments = 4

  /// Pinned message ids in chat order, oldest first.
  public private(set) var messageIds: [Int64] = []
  public private(set) var displayedMessageId: Int64?

  public init(messageIds: [Int64] = []) {
    update(messageIds: messageIds)
  }

  public var count: Int { messageIds.count }
  public var isEmpty: Bool { messageIds.isEmpty }

  /// Index of the shown pin in chat order, 0 being the oldest.
  public var displayedIndex: Int? {
    displayedMessageId.flatMap { messageIds.firstIndex(of: $0) }
  }

  public var title: String {
    guard let index = displayedIndex, count > 1, index != count - 1 else { return "Pinned Message" }
    if count == 2 { return "Previous Message" }
    return "Pinned Message #\(index + 1)"
  }

  /// The run of stripe segments to draw, so the shown pin stays visible when there are more than fit.
  public var visibleStripeRange: Range<Int> {
    guard count > 1, let index = displayedIndex else { return 0 ..< 0 }
    let visible = min(count, Self.maxVisibleStripeSegments)
    // Keep one older segment above the shown one when there is room, hinting that more pins are above.
    let start = min(max(0, index - (visible - 2)), count - visible)
    return start ..< start + visible
  }

  /// Replaces the pin set from the database, in any order.
  public mutating func update(messageIds newIds: some Sequence<Int64>) {
    let previous = Set(messageIds)
    let sorted = Array(Set(newIds)).sorted()
    messageIds = sorted

    if previous.isEmpty {
      displayedMessageId = sorted.last
    } else if let newestAdded = sorted.last(where: { !previous.contains($0) }) {
      displayedMessageId = newestAdded
    } else if let displayed = displayedMessageId, !sorted.contains(displayed) {
      displayedMessageId = sorted.last(where: { $0 < displayed }) ?? sorted.last
    } else if displayedMessageId == nil {
      displayedMessageId = sorted.last
    }
  }

  /// Shows a specific pin, for example one picked from the pinned list.
  public mutating func show(_ messageId: Int64) {
    guard messageIds.contains(messageId) else { return }
    displayedMessageId = messageId
  }

  /// Returns the pin to jump to and moves the header to the next older pin, wrapping to the newest.
  @discardableResult
  public mutating func advance() -> Int64? {
    guard let displayed = displayedMessageId else { return nil }
    displayedMessageId = messageIds.last(where: { $0 < displayed }) ?? messageIds.last
    return displayed
  }
}
