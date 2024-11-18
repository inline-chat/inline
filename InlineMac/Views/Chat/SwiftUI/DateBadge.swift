import InlineKit
import InlineUI
import SwiftUI

struct DateBadge: View {
  var date: Date

  enum Day {
    case today
    case yesterday
    case day(humanReadable: String)

    var description: String {
      switch self {
      case .today: return "Today"
      case .yesterday: return "Yesterday"
      case .day(let humanReadable): return humanReadable
      }
    }
  }

  var day: Day {
    if Calendar.current.isDateInToday(date) {
      return .today
    } else if Calendar.current.isDateInYesterday(date) {
      return .yesterday
    } else {
      return .day(humanReadable: date.formatted(date: .abbreviated, time: .omitted))
    }
  }

  var body: some View {
    HStack {
      Text(day.description)
    }
    .padding(.horizontal, 4)
    .background(Color.gray.opacity(0.1))
    .cornerRadius(12)
    .frame(height: 20)
    .contentShape(Capsule(style: .circular))
  }
}
