import Foundation

struct DailyActivity: Codable, Sendable, Identifiable, Equatable {
  let date: String
  let activeUsers: Int
  var messages: Int? = nil
  var newUsers: Int? = nil
  var id: String { date }
}

enum MetricsDate {
  static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  static func parse(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withFullDate]
    formatter.timeZone = calendar.timeZone
    return formatter.date(from: value)
  }

  static func label(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate("MMMd")
    return formatter.string(from: date)
  }
}

struct DailyMetricPoint: Identifiable, Sendable {
  let date: Date
  let activity: DailyActivity
  var id: Date { date }
  var label: String { MetricsDate.label(date) }
}

struct MetricChange: Equatable, Sendable {
  let current: Int
  let previous: Int
  var direction: Int { current == previous ? 0 : (current > previous ? 1 : -1) }
  var percentage: Double? {
    guard previous > 0 else { return current == 0 ? 0 : nil }
    return (Double(current) - Double(previous)) / Double(previous) * 100
  }
  var text: String {
    guard direction != 0 else { return "—" }
    guard let percentage else { return "New" }
    let amount = abs(percentage)
    return amount < 0.1 ? "<0.1%" : "\(amount.formatted(.number.precision(.fractionLength(0...1))))%"
  }
  var explanation: String {
    "\(current.formatted()) today versus \(previous.formatted()) for all of yesterday (UTC). Today is still in progress."
  }
}

/// Intentionally decodes only aggregates, never the response's recent users/emails or placeholder MRR.
struct OverviewMetrics: Codable, Sendable, Equatable {
  let dau: Int
  let wau: Int
  let messagesToday: Int
  let waitlistCount: Int
  let newUsersLastDay: Int
  let newWaitlistLastDay: Int
  let dailyActivity: [DailyActivity]
  let asOf: String
  let reportingTimeZone: String

  var reportedAt: Date? {
    MetricsDate.parse(asOf)
  }

  var orderedDays: [DailyMetricPoint] {
    var days: [Date: DailyActivity] = [:]
    for day in dailyActivity {
      guard let parsed = MetricsDate.parse(day.date) else { continue }
      days[MetricsDate.calendar.startOfDay(for: parsed)] = day
    }
    return days.map { DailyMetricPoint(date: $0.key, activity: $0.value) }.sorted { $0.date < $1.date }
  }

  var chartDays: [DailyMetricPoint] { Array(orderedDays.suffix(7)) }

  private var yesterday: DailyActivity? {
    guard let reportedAt,
          let day = MetricsDate.calendar.date(byAdding: .day, value: -1, to: MetricsDate.calendar.startOfDay(for: reportedAt))
    else { return nil }
    return dailyActivity.last { activity in
      guard let parsed = MetricsDate.parse(activity.date) else { return false }
      return MetricsDate.calendar.startOfDay(for: parsed) == day
    }
  }

  var activeUsersChange: MetricChange? {
    yesterday.map { MetricChange(current: dau, previous: $0.activeUsers) }
  }
  var messagesChange: MetricChange? {
    yesterday?.messages.map { MetricChange(current: messagesToday, previous: $0) }
  }
  var newUsersChange: MetricChange? {
    yesterday?.newUsers.map { MetricChange(current: newUsersLastDay, previous: $0) }
  }

  /// Changing the server's asOf alone isn't a change in the metrics themselves.
  func hasSameValues(as other: OverviewMetrics) -> Bool {
    let copy = OverviewMetrics(dau: dau, wau: wau, messagesToday: messagesToday,
      waitlistCount: waitlistCount, newUsersLastDay: newUsersLastDay,
      newWaitlistLastDay: newWaitlistLastDay, dailyActivity: dailyActivity,
      asOf: other.asOf, reportingTimeZone: reportingTimeZone)
    return copy == other
  }
}

struct OverviewResponse: Decodable, Sendable {
  let ok: Bool
  let metrics: OverviewMetrics
}

struct MetricsSnapshot: Codable, Sendable {
  enum State: String, Codable, Sendable {
    case ready, signedOut, expired, unavailable
  }

  var state: State
  var metrics: OverviewMetrics?
  var fetchedAt: Date?
  var sessionExpiresAt: Date?

  static let signedOut = MetricsSnapshot(state: .signedOut)
  static let staleAfter: TimeInterval = 45 * 60
  static let refreshInterval: TimeInterval = 5 * 60
  static let widgetRefreshInterval: TimeInterval = 15 * 60

  func needsWidgetReload(comparedTo previous: MetricsSnapshot?, lastReload: Date?, now: Date) -> Bool {
    guard let previous, let lastReload else { return true }
    if state != previous.state || sessionExpiresAt != previous.sessionExpiresAt { return true }
    switch (metrics, previous.metrics) {
    case let (current?, old?):
      if !current.hasSameValues(as: old) { return true }
    case (nil, nil): break
    default: return true
    }
    return now.timeIntervalSince(lastReload) >= Self.widgetRefreshInterval
  }

  func visibleMetrics(at now: Date) -> OverviewMetrics? {
    guard state == .ready || state == .unavailable else { return nil }
    guard sessionExpiresAt.map({ $0 > now }) ?? false else { return nil }
    return metrics
  }

  func status(at now: Date) -> String {
    if state == .signedOut { return "Sign in to Inline Metrics" }
    if state == .expired || sessionExpiresAt.map({ $0 <= now }) == true { return "Sign in again" }
    if state == .unavailable { return "Offline · showing saved metrics" }
    if let fetchedAt, now.timeIntervalSince(fetchedAt) >= Self.staleAfter {
      return "Open Inline Metrics to update"
    }
    return "Updated"
  }

  /// Used only in previews and WidgetKit's placeholder, never persisted as live data.
  static var sample: MetricsSnapshot {
    MetricsSnapshot(
      state: .ready,
      metrics: OverviewMetrics(
        dau: 128, wau: 342, messagesToday: 1846, waitlistCount: 620,
        newUsersLastDay: 12, newWaitlistLastDay: 24,
        dailyActivity: [84, 96, 91, 110, 103, 150, 128].enumerated().map {
          let date = MetricsDate.calendar.date(byAdding: .day, value: $0.offset - 6, to: MetricsDate.calendar.startOfDay(for: Date()))!
          return DailyActivity(date: ISO8601DateFormatter().string(from: date), activeUsers: $0.element,
            messages: 1500, newUsers: 16)
        },
        asOf: ISO8601DateFormatter().string(from: Date()), reportingTimeZone: "UTC"
      ),
      fetchedAt: Date(), sessionExpiresAt: Date().addingTimeInterval(86_400)
    )
  }
}
