import Foundation

/// A server message coordinate, independent of row indexes and cached geometry.
public struct MessageListViewportAnchor: Codable, Equatable, Sendable {
  public let messageID: Int64
  public let offsetY: Double

  public init?(messageID: Int64, offsetY: Double) {
    guard messageID > 0, offsetY.isFinite else { return nil }
    self.messageID = messageID
    self.offsetY = offsetY
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let messageID = try values.decode(Int64.self, forKey: .messageID)
    let offsetY = try values.decode(Double.self, forKey: .offsetY)
    guard let anchor = Self(messageID: messageID, offsetY: offsetY) else {
      throw DecodingError.dataCorruptedError(
        forKey: .messageID,
        in: values,
        debugDescription: "Invalid viewport anchor"
      )
    }
    self = anchor
  }
}

public enum MessageListInitialPosition: Codable, Equatable, Sendable {
  case latest
  case anchor(MessageListViewportAnchor)

  public var messageID: Int64? {
    guard case let .anchor(anchor) = self else { return nil }
    return anchor.messageID
  }

  public var followsLatest: Bool {
    self == .latest
  }
}

public enum MessageListViewportGeometry {
  /// AppKit's document origin includes the negative top inset and positive bottom inset.
  public static func clampedOffset(
    _ offset: Double, contentHeight: Double, viewportHeight: Double,
    topInset: Double, bottomInset: Double
  ) -> Double {
    guard [offset, contentHeight, viewportHeight, topInset, bottomInset].allSatisfy(\.isFinite) else { return 0 }
    let lower = -max(0, topInset)
    let upper = max(lower, contentHeight + max(0, bottomInset) - max(0, viewportHeight))
    return min(max(offset, lower), upper)
  }

  /// Only call after the history window certifies the neighborhood of a missing coordinate.
  public static func nearestMessage(to target: Int64, in ids: [Int64]) -> Int64? {
    if ids.contains(target) { return target }
    return ids.lazy.filter { $0 > target }.min() ?? ids.lazy.filter { $0 > 0 && $0 < target }.max()
  }
}
