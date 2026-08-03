import Foundation

/// Matches the compact time/date treatment used by macOS All Chats without installing a
/// continuously updating relative-date timer in every visible row.
public enum ChatListDateFormatter {
  public static func rowTitle(
    for date: Date?,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
  ) -> String? {
    guard let date, date != .distantPast else { return nil }

    let age = now.timeIntervalSince(date)
    if age >= 0, age < 60 {
      return "just now"
    }

    if calendar.isDate(date, inSameDayAs: now) {
      return date.formatted(date: .omitted, time: .shortened)
    }

    let day = calendar.startOfDay(for: date)
    let today = calendar.startOfDay(for: now)
    let days = calendar.dateComponents([.day], from: day, to: today).day
    if let days, days > 0, days < 7 {
      return date.formatted(.dateTime.weekday(.abbreviated))
    }

    if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
      return date.formatted(.dateTime.month(.abbreviated).day())
    }

    return date.formatted(.dateTime.month(.abbreviated).day().year())
  }
}
