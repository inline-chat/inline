import InlineKit
import InlineUI
import SwiftUI
import UIKit

struct ChatRowView: View {
  let item: HomeChatItem
  var type: ChatType {
    item.chat?.type ?? .privateChat
  }

  @ObservedObject var composeActions: ComposeActions = .shared

  private func currentComposeAction() -> ApiComposeAction? {
    composeActions.getComposeAction(for: Peer(userId: item.user.id))?.action
  }

  var body: some View {
    HStack(alignment: .top) {
      if item.user.id == Auth.shared.getCurrentUserId() {
        savedMessageSymbol
      } else {
        UserAvatar(user: item.user, size: 36)
          .padding(.trailing, 6)
          .overlay(alignment: .bottomTrailing) {
            if item.user.online == true {
              Circle()
                .fill(.green)
                .frame(width: 10, height: 10)
                .padding(.leading, -15)
                .padding(.top, -14)
            }
          }
      }

      VStack(alignment: .leading) {
        HStack {
          Text(
            type == .privateChat
              ? item.user.id == Auth.shared.getCurrentUserId()
              ? "Saved Message" : item.user.firstName ?? "" : item.chat?.title ?? ""
          )
          .fontWeight(.medium)
          .foregroundColor(.primary)
          Spacer()
          Text(item.message?.date.formatted() ?? "")
            .font(.callout)
            .foregroundColor(.secondary)
        }

        if currentComposeAction()?.rawValue.isEmpty == false {
          Text("\(currentComposeAction()?.rawValue ?? "")...")
            .font(.callout)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let text = item.message?.text {
          Text(text.replacingOccurrences(of: "\n", with: " "))
            .font(.callout)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          Text("No messages yet")
            .font(.callout)
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
      }
    }
    .frame(height: 48)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }

  @ViewBuilder
  var savedMessageSymbol: some View {
    Circle()
      .fill(
        LinearGradient(
          colors: [
            ColorManager.shared.swiftUIColor.adjustLuminosity(by: 0.3),
            ColorManager.shared.swiftUIColor.adjustLuminosity(by: -0.1),
          ], startPoint: .topLeading, endPoint: .bottomTrailing
        )
      )
      .frame(width: 36, height: 36)
      .overlay(alignment: .center) {
        Image(systemName: "bookmark.fill")
          .foregroundColor(.white)
          .font(.callout)
      }
      .padding(.trailing, 6)
  }
}

#Preview("ChatRowView") {
  VStack(spacing: 12) {
    // Private chat example
    let privateDialog = Dialog(optimisticForUserId: 2)

    let privateUser = User(
      id: 2,
      email: "john@example.com",
      firstName: "Dena",
      lastName: "Doe"
    )

    let privateChat = Chat(
      id: 1,
      date: Date(),
      type: .privateChat,
      title: "John Doe",
      spaceId: nil,
      peerUserId: 2,
      lastMsgId: nil
    )

    ChatRowView(
      item: HomeChatItem(
        dialog: privateDialog, user: privateUser, chat: privateChat,
        message: Message(
          messageId: 1,
          fromId: 2,
          date: Date(),
          text: "فارسی هم ساپورت میکنه به به",
          peerUserId: 2,
          peerThreadId: nil,
          chatId: 1
        )
      )
      // item: HomeChatItem(
      //   dialog: privateDialog,
      //   user: privateUser,
      //   chat: privateChat,
      // message:
      // )
    )
    .padding()
  }
}
