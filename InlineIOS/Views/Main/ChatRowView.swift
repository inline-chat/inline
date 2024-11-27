import InlineKit
import InlineUI
import SwiftUI
import UIKit

struct ChatRowView: View {
  let item: HomeChatItem
  var type: ChatType {
    item.chat?.type ?? .privateChat
  }

  private func formatDate(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
      let formatter = DateFormatter()
      formatter.dateFormat = "h:mm a"
      formatter.amSymbol = ""  // Remove AM
      return formatter.string(from: date).replacingOccurrences(of: " PM", with: "PM")
    } else {
      let formatter = DateFormatter()
      formatter.dateFormat = "MMM d, h:mm"
      return formatter.string(from: date)
    }
  }

  var body: some View {
    HStack {
      UserAvatar(user: item.user, size: 36)
        .padding(.trailing, 6)
      VStack(alignment: .leading) {
        HStack {
          Text(type == .privateChat ? item.user.firstName ?? "" : item.chat?.title ?? "")
            .fontWeight(.medium)
          Spacer()
          Text(formatDate(item.message?.date ?? Date()))
            .font(.callout)
            .foregroundColor(.secondary)

        }
        Text((item.message?.text ?? "").replacingOccurrences(of: "\n", with: " "))
          .font(.callout)
          .foregroundColor(.secondary)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(height: 48)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}
