import Foundation
import InlineKit

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

public func getStatusText(_ state: RealtimeAPIState) -> String {
  switch state {
    case .connected:
      "Connected"
    case .connecting:
      "Connecting"
    case .updating:
      "Updating"
    case .waitingForNetwork:
      "Waiting for network"
  }
}

public func getStatusTextForChatHeader(_ state: RealtimeAPIState) -> String {
  switch state {
    case .connected:
      "connected"
    case .connecting:
      "connecting..."
    case .updating:
      "updating..."
    case .waitingForNetwork:
      "waiting for network"
  }
}

public func getDenaOrMoUserId(username: String) -> Int64 {
  #if DEBUG
  if username == "mo" {
    return 1_300
  } else if username == "dena" {
    return 1_000
  } else {
    return 0
  }
  #else
  // Production environment
  if username == "mo" {
    return 1_600
  } else if username == "dena" {
    return 4_000
  } else {
    return 0
  }
  #endif
}
