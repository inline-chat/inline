import Foundation

/// Matches the compact absolute-time treatment used by All Chats without installing a
/// continuously updating relative-date timer in every visible row.
public enum ChatListDateFormatter {
  public static func rowTitle(
    for date: Date?,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
  ) -> String? {
    guard let date, date != .distantPast else { return nil }
    guard calendar.isDate(date, inSameDayAs: now) else { return nil }

    return date.formatted(date: .omitted, time: .shortened)
  }
}
