import InlineKit
import InlineUI
import SwiftUI

struct ChatRowView: View {
  let item: HomeChatItem
  var type: ChatType {
    item.chat?.type ?? .privateChat
  }

  var body: some View {
    HStack {
      InitialsCircle(
        firstName: type == .privateChat
          ? item.user.firstName ?? "" : item.chat?.title ?? "",
        lastName: item.chat?.type == .privateChat ? item.user.lastName ?? "" : nil, size: 26
      )
      .padding(.trailing, 6)
      VStack(alignment: .leading) {
        Text(type == .privateChat ? item.user.firstName ?? "" : item.chat?.title ?? "")
          .fontWeight(.medium)
        Text(item.message?.text ?? "")
          .font(.body)
          .foregroundColor(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}
