import InlineKit
import InlineUI
import SwiftUI
import UIKit

struct ChatRowView: View {
  let item: HomeChatItem
  var type: ChatType {
    item.chat?.type ?? .privateChat
  }

  var body: some View {
    HStack {
      UserAvatar(user: item.user, size: 28)
        .padding(.trailing, 6)
      VStack(alignment: .leading) {
        Text(type == .privateChat ? item.user.firstName ?? "" : item.chat?.title ?? "")
          .fontWeight(.medium)
        Text(item.message?.text ?? "")
          .font(.body)
          .foregroundColor(.secondary)
      }
    }
    .frame(height: 48)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())

  }
}
