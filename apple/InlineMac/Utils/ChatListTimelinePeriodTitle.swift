import Foundation
import InlineKit

enum ChatListTimelinePeriodTitle {
  static func string(
    for period: ChatListTimelinePeriod,
    calendar: Calendar
  ) -> String {
    switch period {
    case let .day(day):
      if calendar.isDateInToday(day) {
        return String(localized: "Today")
      }
      if calendar.isDateInYesterday(day) {
        return String(localized: "Yesterday")
      }
      return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    case let .month(year, month):
      guard let date = calendar.date(
        from: DateComponents(year: year, month: month, day: 1)
      ) else { return "\(month)" }
      return date.formatted(.dateTime.month(.wide))
    case let .year(year):
      guard let date = calendar.date(
        from: DateComponents(year: year, month: 1, day: 1)
      ) else { return "\(year)" }
      return date.formatted(.dateTime.year())
    }
  }
}
