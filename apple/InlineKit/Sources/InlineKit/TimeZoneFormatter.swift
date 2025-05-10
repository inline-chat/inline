import Foundation

public final class TimeZoneFormatter: @unchecked Sendable {
  public static let shared = TimeZoneFormatter()

  public let dateFormatter: DateFormatter

  public init() {
    dateFormatter = DateFormatter()
    dateFormatter.timeStyle = .short
    dateFormatter.dateStyle = .none
  }

  public func formatTimeZoneInfo(userTimeZoneId: String) -> String? {
    guard let userTimeZone = TimeZone(identifier: userTimeZoneId),
          userTimeZone != TimeZone.current
    else {
      return nil
    }

    dateFormatter.timeZone = userTimeZone
    let localTime = dateFormatter.string(from: Date())

    let hourDifference = (Double(userTimeZone.secondsFromGMT()) - Double(TimeZone.current.secondsFromGMT())) / 3_600.0
    let timeDiff = if hourDifference >= 0 {
      "+\(String(format: "%.1f", hourDifference).replacingOccurrences(of: ".0", with: ""))"
    } else {
      "\(String(format: "%.1f", hourDifference).replacingOccurrences(of: ".0", with: ""))"
    }

    return "\(localTime) (\(timeDiff) hr)"
  }
}
