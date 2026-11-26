import Foundation

/// Matches the compact absolute time/date treatment used by chat sidebars without installing a
/// continuously updating relative-date timer in every visible row.
public enum ChatListDateFormatter {
  public static func rowTitle(
    for date: Date?,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
  ) -> String? {
    rowTitle(for: date, context: RowTitleContext(now: now, calendar: calendar))
  }

  /// Titles a row against day boundaries computed once. Calendar arithmetic per row was a quarter
  /// of each chat-list refresh; a list builds one context per fetch.
  public static func rowTitle(for date: Date?, context: RowTitleContext) -> String? {
    guard let date, date != .distantPast else { return nil }
    if context.today.contains(date), date < context.today.end {
      return date.formatted(date: .omitted, time: .shortened)
    }
    if date >= context.startOfWeekWindow, date < context.today.start {
      return date.formatted(.dateTime.weekday(.abbreviated))
    }
    if context.year.contains(date), date < context.year.end {
      return date.formatted(.dateTime.month(.abbreviated).day())
    }
    return date.formatted(.dateTime.month(.abbreviated).day().year())
  }

  /// The day, the six days before it and the year containing `now`, in `calendar`.
  public struct RowTitleContext: Sendable {
    let today: DateInterval
    /// Start of the day six days before today: dates from here until today show a weekday.
    let startOfWeekWindow: Date
    let year: DateInterval

    public init(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
      let today = calendar.dateInterval(of: .day, for: now) ?? DateInterval(start: now, duration: 0)
      self.today = today
      // Step back from midday so a day that starts at 01:00 (a DST change at midnight) still lands
      // inside the right day; then take that day's real start.
      let midday = calendar.date(byAdding: .hour, value: 12, to: today.start) ?? today.start
      let sixDaysBefore = calendar.date(byAdding: .day, value: -6, to: midday) ?? today.start
      startOfWeekWindow = calendar.startOfDay(for: sixDaysBefore)
      year = calendar.dateInterval(of: .year, for: now) ?? today
    }
  }
}
