import CoreGraphics
import Foundation

public enum MessageSwipeToReplyDirection: String, CaseIterable, Identifiable, Codable, Sendable {
  case leftToRight
  case rightToLeft

  public static let storageKey = "messageSwipeToReplyDirection"
  public static let defaultValue: Self = .rightToLeft

  public var id: String { rawValue }

  public var title: String {
    switch self {
      case .leftToRight:
        "Right"
      case .rightToLeft:
        "Left"
    }
  }

  public var horizontalSign: CGFloat {
    switch self {
      case .leftToRight:
        1
      case .rightToLeft:
        -1
    }
  }

  public var revealsLeftEdge: Bool {
    self == .leftToRight
  }

  public func accepts(_ horizontalOffset: CGFloat) -> Bool {
    horizontalOffset * horizontalSign > 0
  }

  public func boundedOffset(_ horizontalOffset: CGFloat, maximum: CGFloat) -> CGFloat {
    guard accepts(horizontalOffset), maximum > 0 else { return 0 }
    return horizontalSign * min(abs(horizontalOffset), maximum)
  }

  public static func stored(in defaults: UserDefaults = .standard) -> Self {
    guard
      let rawValue = defaults.string(forKey: storageKey),
      let direction = Self(rawValue: rawValue)
    else {
      return defaultValue
    }
    return direction
  }
}
