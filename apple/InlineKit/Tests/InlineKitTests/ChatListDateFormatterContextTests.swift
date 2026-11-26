import Foundation
@testable import InlineKit
import Testing

/// `ChatListDateFormatter.rowTitle(for:context:)` compares against day boundaries computed once per list
/// fetch. It titles every date by calendar days, checked here against a per-row reference.
///
/// The per-row code it replaced counted days between two `startOfDay` values, which counts 0 across a
/// 23-hour day that starts at 01:00 (DST at midnight: Havana, Santiago, Beirut, Cairo, the Azores). Dates
/// on and around those days got the wrong title ("Mar 8" for yesterday, a weekday for a week ago). The
/// reference counts days from noon to noon instead, so those days are checked too.
@Suite("Chat list row title context")
struct ChatListDateFormatterContextTests {
  @Test(
    "titles by calendar days across time zones, DST changes and calendars",
    arguments: [
      "UTC", "America/New_York", "Europe/London", "America/Santiago", "America/Havana", "Asia/Beirut",
      "Africa/Cairo", "Atlantic/Azores", "Asia/Tehran", "Australia/Lord_Howe", "Asia/Kolkata",
    ]
  )
  func matchesReference(timeZoneID: String) throws {
    let timeZone = try #require(TimeZone(identifier: timeZoneID))
    for identifier in [Calendar.Identifier.gregorian, .persian, .buddhist] {
      var calendar = Calendar(identifier: identifier)
      calendar.timeZone = timeZone
      // "Now" values around DST changes, midnight and the turn of the year, plus ordinary days. The
      // March 9/15 and September 7/13 values sit one and seven days after the 23-hour days in Havana and
      // Santiago.
      let nows: [Date] = [
        "2026-01-01T00:30:00Z", "2026-03-08T07:30:00Z", "2026-03-09T17:00:00Z", "2026-03-15T17:00:00Z",
        "2026-03-29T00:30:00Z", "2026-04-05T03:10:00Z", "2026-04-25T09:00:00Z", "2026-09-06T04:00:00Z",
        "2026-09-07T15:00:00Z", "2026-09-13T15:00:00Z", "2026-10-25T01:30:00Z", "2026-10-31T12:00:00Z",
        "2026-11-01T05:30:00Z", "2026-11-26T12:00:00Z", "2026-12-31T23:30:00Z", "2027-03-20T20:45:00Z",
      ].map { ISO8601DateFormatter().date(from: $0)! }
      for now in nows {
        let context = ChatListDateFormatter.RowTitleContext(now: now, calendar: calendar)
        // Every 23 minutes from 10 days before to 3 days after (today, the week window, and the turn of
        // the year for the January and December "now" values), then daily steps back to 400 days, plus
        // one second either side of each day start in that range and of the year's start and end.
        let fine = stride(from: -10.0 * 86_400, to: 3 * 86_400, by: 23 * 60).map { now.addingTimeInterval($0) }
        let coarse = stride(from: -400.0 * 86_400, to: -10 * 86_400, by: 86_400 + 7 * 60)
          .map { now.addingTimeInterval($0) }
        var boundaries: [Date] = []
        var dayStart = calendar.startOfDay(for: now.addingTimeInterval(-10 * 86_400))
        while dayStart < now.addingTimeInterval(3 * 86_400) {
          boundaries += [dayStart.addingTimeInterval(-1), dayStart, dayStart.addingTimeInterval(1)]
          dayStart = try #require(calendar.date(byAdding: .day, value: 1, to: dayStart.addingTimeInterval(12 * 3600)))
          dayStart = calendar.startOfDay(for: dayStart)
        }
        if let year = calendar.dateInterval(of: .year, for: now) {
          boundaries += [year.start, year.end].flatMap { [$0.addingTimeInterval(-1), $0, $0.addingTimeInterval(1)] }
        }
        for date in fine + coarse + boundaries {
          let expected = Self.referenceRowTitle(for: date, now: now, calendar: calendar)
          let actual = ChatListDateFormatter.rowTitle(for: date, context: context)
          if actual != expected {
            Issue.record("\(timeZoneID) \(identifier) now=\(now) date=\(date): \(actual ?? "nil") != \(expected ?? "nil")")
            return
          }
        }
      }
    }
  }

  @Test("nil and distantPast have no title")
  func emptyDates() {
    let context = ChatListDateFormatter.RowTitleContext()
    #expect(ChatListDateFormatter.rowTitle(for: nil, context: context) == nil)
    #expect(ChatListDateFormatter.rowTitle(for: .distantPast, context: context) == nil)
  }

  /// Per-row reference: the per-row code this replaced, with days counted from noon to noon (so a 23-hour
  /// day counts as one) and years compared with their era.
  private static func referenceRowTitle(for date: Date?, now: Date, calendar: Calendar) -> String? {
    guard let date, date != .distantPast else { return nil }
    if calendar.isDate(date, inSameDayAs: now) {
      return date.formatted(date: .omitted, time: .shortened)
    }

    // Noon exists on every day, including those that start at 01:00.
    if let dayNoon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date),
       let todayNoon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now),
       let days = calendar.dateComponents([.day], from: dayNoon, to: todayNoon).day,
       days > 0, days < 7
    {
      return date.formatted(.dateTime.weekday(.abbreviated))
    }

    if calendar.dateComponents([.era, .year], from: date) == calendar.dateComponents([.era, .year], from: now) {
      return date.formatted(.dateTime.month(.abbreviated).day())
    }

    return date.formatted(.dateTime.month(.abbreviated).day().year())
  }

  @Test("titles the day after a 23-hour day as yesterday's weekday, and a week back by its date")
  func shortDayCountsAsADay() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Havana"))
    let formatter = ISO8601DateFormatter()
    // Sunday March 8, 2026 starts at 01:00 in Havana (DST at midnight) and lasts 23 hours.
    let shortDay = try #require(formatter.date(from: "2026-03-08T15:00:00Z"))
    let nextDay = try #require(formatter.date(from: "2026-03-09T17:00:00Z"))
    let weekLater = try #require(formatter.date(from: "2026-03-15T17:00:00Z"))
    #expect(
      ChatListDateFormatter.rowTitle(for: shortDay, context: .init(now: nextDay, calendar: calendar))
        == shortDay.formatted(.dateTime.weekday(.abbreviated))
    )
    #expect(
      ChatListDateFormatter.rowTitle(for: shortDay, context: .init(now: weekLater, calendar: calendar))
        == shortDay.formatted(.dateTime.month(.abbreviated).day())
    )
  }
}
