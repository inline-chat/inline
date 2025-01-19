import Foundation

public extension Date {
  func formatted() -> String {
    let calendar = Calendar.current
    let now = Date()
    let components = calendar.dateComponents([.day], from: self, to: now)
    let daysAgo = components.day ?? 0

    if calendar.isDateInToday(self) {
      // Today: Show time in 24-hour format
      let formatter = DateFormatter()
      formatter.dateFormat = "HH:mm"
      return formatter.string(from: self)
    } else if calendar.isDateInYesterday(self) {
      // Yesterday
      return "Yesterday"
    } else if daysAgo < 7 {
      // Within last week: Show day name
      let formatter = DateFormatter()
      formatter.dateFormat = "EEEE"
      return formatter.string(from: self)
    } else {
      // Older messages: Show date
      let formatter = DateFormatter()
      formatter.dateFormat = "dd/MM/yy"
      return formatter.string(from: self)
    }
  }
}
