import Foundation

/// Section header text for the chat info media, files, links and voice tabs.
@MainActor
enum ChatInfoSectionDate {
  static func text(for date: Date) -> String {
    let calendar = Calendar.current

    if calendar.isDateInToday(date) {
      return "Today"
    } else if calendar.isDateInYesterday(date) {
      return "Yesterday"
    } else if calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
      return weekdayFormatter.string(from: date)
    } else {
      return fullDateFormatter.string(from: date)
    }
  }

  private static let weekdayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "EEEE"
    return formatter
  }()

  private static let fullDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "MMMM d, yyyy"
    return formatter
  }()
}
