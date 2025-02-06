import InlineKit
import InlineUI
import SwiftUI
import UIKit

struct ChatRowView: View {
  let item: ChatRowItem
  var type: ChatType {
    switch item {
      case let .home(homeItem):
        homeItem.chat?.type ?? .privateChat
      case let .space(spaceItem):
        spaceItem.chat?.type ?? .privateChat
    }
  }

  let showPinned: Bool

  init(item: ChatRowItem, showPinned: Bool = true) {
    self.item = item
    self.showPinned = showPinned
  }

  @ObservedObject var composeActions: ComposeActions = .shared

  private func currentComposeAction() -> ApiComposeAction? {
    switch item {
      case let .home(homeItem):
        composeActions.getComposeAction(for: Peer(userId: homeItem.user.id))?.action
      case .space:
        nil
    }
  }

  private var pinned: Bool {
    switch item {
      case let .home(homeItem):
        homeItem.dialog.pinned ?? false
      case let .space(spaceItem):
        spaceItem.dialog.pinned ?? false
    }
  }

  private var isCurrentUser: Bool {
    switch item {
      case let .home(homeItem):
        homeItem.user.id == Auth.shared.getCurrentUserId()
      case let .space(spaceItem):
        spaceItem.user?.id == Auth.shared.getCurrentUserId()
    }
  }

  private var showTypingIndicator: Bool {
    currentComposeAction()?.rawValue.isEmpty == false
  }

  private var senderName: String {
    switch item {
      case let .home(homeItem):
        if homeItem.from?.id == Auth.shared.getCurrentUserId() {
          "You"
        } else {
          homeItem.from?.firstName ?? ""
        }
      case let .space(spaceItem):
        if let user = spaceItem.user {
          user.fullName
        } else {
          spaceItem.chat?.title ?? ""
        }
    }
  }

  var hasUnread: Bool {
    switch item {
      case let .home(homeItem):
        homeItem.dialog.unreadCount ?? 0 > 0
      case let .space(spaceItem):
        spaceItem.dialog.unreadCount ?? 0 > 0
    }
  }

  var body: some View {
    HStack(alignment: .top) {
      switch item {
        case let .home(homeItem):
          if isCurrentUser {
            savedMessageSymbol
          } else {
            userAvatar(homeItem.user.user)
          }
        case let .space(spaceItem):
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

        HStack(alignment: .top) {
          if showTypingIndicator {
            Text("\(currentComposeAction()?.rawValue ?? "")...")
              .font(.callout)
              .foregroundColor(.secondary)
              .lineLimit(2)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else if let lastMsgText = getMessage()?.text {
            Text(
              "\(senderName): \(lastMsgText.replacingOccurrences(of: "\n", with: " "))"
            )
            .font(.callout)
            .foregroundColor(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            Text("No messages yet")
              .font(.callout)
              .foregroundColor(.secondary)
              .lineLimit(2)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .overlay(alignment: .topTrailing) {
          Group {
            if pinned && showPinned && !hasUnread {
              Image(systemName: "pin.fill")
                .foregroundColor(.secondary)
                .font(.caption)
            } else if hasUnread {
              Circle()
                .fill(Color.blue)
                .frame(width: 10, height: 10)
            }
          }
          .padding(.top, 4)
        }
        Spacer()
      }
    }
    .padding(.top, 8)
    .frame(height: 66)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }

  private func getMessage() -> Message? {
    switch item {
      case let .home(homeItem):
        homeItem.message
      case let .space(spaceItem):
        spaceItem.message
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
  }

  @ViewBuilder
  var chatTitle: some View {
    switch item {
      case let .home(homeItem):
        Text(
          type == .privateChat
            ? homeItem.user.id == Auth.shared.getCurrentUserId()
            ? "Saved Message" : homeItem.user.user.firstName ?? ""
            : homeItem.chat?.title ?? ""
        )
        .fontWeight(.medium)
        .foregroundColor(.primary)
      case let .space(spaceItem):
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
