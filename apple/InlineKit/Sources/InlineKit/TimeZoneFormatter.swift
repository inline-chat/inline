import Foundation

public final class TimeZoneFormatter: @unchecked Sendable {
  public static let shared = TimeZoneFormatter()

  public let dateFormatter: DateFormatter
  private let lock = NSLock()
  private var viewerTimeZoneOverride: TimeZone?

  public init() {
    dateFormatter = DateFormatter()
    dateFormatter.timeStyle = .short
    dateFormatter.dateStyle = .none
  }

  /// The time zone other people's local time is compared with: the one the
  /// user picked in privacy settings, or this device's.
  public var viewerTimeZone: TimeZone {
    lock.withLock { viewerTimeZoneOverride } ?? .autoupdatingCurrent
  }

  /// Follows the manual time zone setting; nil or empty uses this device's.
  public func setViewerTimeZone(identifier: String?) {
    let timeZone = identifier.flatMap { $0.isEmpty ? nil : TimeZone(identifier: $0) }
    lock.withLock { viewerTimeZoneOverride = timeZone }
  }

  /// Whether a time zone is the viewer's own, so its local time adds nothing.
  public func matchesViewer(timeZoneId: String) -> Bool {
    timeZoneId == viewerTimeZone.identifier
  }

  public func formatTimeZoneInfo(userTimeZoneId: String) -> String? {
    let viewerTimeZone = viewerTimeZone
    guard let userTimeZone = TimeZone(identifier: userTimeZoneId),
          userTimeZone.identifier != viewerTimeZone.identifier
    else {
      return nil
    }

    let localTime = lock.withLock {
      dateFormatter.timeZone = userTimeZone
      return dateFormatter.string(from: Date())
    }

    let hourDifference = (Double(userTimeZone.secondsFromGMT()) - Double(viewerTimeZone.secondsFromGMT())) / 3_600.0
    let timeDiff = if hourDifference >= 0 {
      "+\(String(format: "%.1f", hourDifference).replacingOccurrences(of: ".0", with: ""))"
    } else {
      "\(String(format: "%.1f", hourDifference).replacingOccurrences(of: ".0", with: ""))"
    }

    return "\(localTime) (\(timeDiff) hr)"
  }
}
