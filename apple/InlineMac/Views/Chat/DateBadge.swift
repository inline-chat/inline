import InlineKit
import InlineUI
import SwiftUI

struct DateBadge: View {
  var date: Date
  var action: (() -> Void)?

  init(date: Date, action: (() -> Void)? = nil) {
    self.date = date
    self.action = action
  }

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
        .font(.body)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(.regularMaterial)
        .clipShape(Capsule(style: .circular))
    }
    // Used to add distance to the top edge
    .padding(.top, 10)
    .contentShape(Rectangle())
    .onTapGesture {
      action?()
    }
  }
}
