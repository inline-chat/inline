import InlineKit
import InlineUI
import SwiftUI
import UIKit

struct ChatRowView: View {
  let item: ChatRowItem
  var type: ChatType {
    switch item {
    case .home(let homeItem):
      return homeItem.chat?.type ?? .privateChat
    case .space(let spaceItem):
      return spaceItem.chat?.type ?? .privateChat
    }
  }

  @ObservedObject var composeActions: ComposeActions = .shared

  private func currentComposeAction() -> ApiComposeAction? {
    switch item {
    case .home(let homeItem):
      return composeActions.getComposeAction(for: Peer(userId: homeItem.user.id))?.action
    case .space:
      return nil
    }
  }

  private var pinned: Bool {
    switch item {
    case .home(let homeItem):
      return homeItem.dialog.pinned ?? false
    case .space(let spaceItem):
      return spaceItem.dialog.pinned ?? false
    }
  }

  private var isCurrentUser: Bool {
    switch item {
    case .home(let homeItem):
      return homeItem.user.id == Auth.shared.getCurrentUserId()
    case .space(let spaceItem):
      return spaceItem.user?.id == Auth.shared.getCurrentUserId()
    }
  }

  private var showTypingIndicator: Bool {
    currentComposeAction()?.rawValue.isEmpty == false
  }

  private var senderName: String {
    switch item {
    case .home(let homeItem):
      if homeItem.from?.id == Auth.shared.getCurrentUserId() {
        return "You"
      } else {
        return homeItem.from?.firstName ?? ""
      }
    case .space(let spaceItem):
      if let user = spaceItem.user {
        return user.fullName
      } else {
        return spaceItem.chat?.title ?? ""
      }
    }
  }

  var body: some View {
    HStack(alignment: .top) {
      switch item {
      case .home(let homeItem):
        if isCurrentUser {
          savedMessageSymbol
        } else {
          userAvatar(homeItem.user)
        }
      case .space(let spaceItem):
        if isCurrentUser {
          savedMessageSymbol
        } else {
          spaceAvatar(spaceItem)
        }
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
          } else if let lastMsgText = getMessage()?.text {
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
              .frame(maxWidth: .infinity, alignment: .leading)
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

  private func getMessage() -> Message? {
    switch item {
    case .home(let homeItem):
      return homeItem.message
    case .space(let spaceItem):
      return spaceItem.message
    }
  }

  @ViewBuilder
  func spaceAvatar(_ item: SpaceChatItem) -> some View {
    InitialsCircle(name: item.title ?? "", size: 36)
      .padding(.trailing, 6)
  }

  @ViewBuilder
  func userAvatar(_ user: User) -> some View {
    UserAvatar(user: user, size: 42)
      .padding(.trailing, 6)
      .overlay(alignment: .bottomTrailing) {
        if user.online == true {
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
    switch item {
    case .home(let homeItem):
      Text(
        type == .privateChat
          ? homeItem.user.id == Auth.shared.getCurrentUserId()
            ? "Saved Message" : homeItem.user.firstName ?? ""
          : homeItem.chat?.title ?? ""
      )
      .fontWeight(.medium)
      .foregroundColor(.primary)
    case .space(let spaceItem):
      Text(
        type == .privateChat
          ? spaceItem.user?.id == Auth.shared.getCurrentUserId()
            ? "Saved Message" : spaceItem.user?.firstName ?? ""
          : spaceItem.chat?.title ?? ""
      )
      .fontWeight(.medium)
      .foregroundColor(.primary)
    }
  }

  @ViewBuilder
  var messageDate: some View {
    Text(getMessage()?.date.formatted() ?? "")
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
      .frame(width: 42, height: 42)
      .overlay(alignment: .center) {
        Image(systemName: "bookmark.fill")
          .foregroundColor(.white)
          .font(.callout)
      }
      .padding(.trailing, 6)
  }
}

enum ChatRowItem {
  case home(HomeChatItem)
  case space(SpaceChatItem)
}
