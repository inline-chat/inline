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

  private var pinned: Bool {
    item.dialog.pinned ?? false
  }

  private var isCurrentUser: Bool {
    item.user.id == Auth.shared.getCurrentUserId()
  }

  private var showTypingIndicator: Bool {
    currentComposeAction()?.rawValue.isEmpty == false
  }

  private var senderName: String {
    item.from?.firstName ?? ""
  }

  var body: some View {
    HStack(alignment: .top) {
      if isCurrentUser {
        savedMessageSymbol
      } else {
        userAvatar
      }

      VStack(alignment: .leading) {
        HStack {
          chatTitle
          Spacer()

          messageDate
        }
        HStack {
          if showTypingIndicator {
            Text("\(currentComposeAction()?.rawValue ?? "")...")
              .font(.callout)
              .foregroundColor(.secondary)
              .lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else if let lastMsgText = item.message?.text {
            Text(
              "\(senderName): \(lastMsgText.replacingOccurrences(of: "\n", with: " "))"
            )
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
          if pinned {
            Image(systemName: "pin.fill")
              .foregroundColor(.secondary)
              .font(.caption)
          }
        }
      }
    }
    .frame(height: 48)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }

  @ViewBuilder
  var userAvatar: some View {
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

  @ViewBuilder
  var chatTitle: some View {
    Text(
      type == .privateChat
        ? item.user.id == Auth.shared.getCurrentUserId()
        ? "Saved Message" : item.user.firstName ?? "" : item.chat?.title ?? ""
    )
    .fontWeight(.medium)
    .foregroundColor(.primary)
  }

  @ViewBuilder
  var messageDate: some View {
    Text(item.message?.date.formatted() ?? "")
      .font(.callout)
      .foregroundColor(.secondary)
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
