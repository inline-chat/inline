import InlineKit
import InlineUI
import SwiftUI

struct ChatListItem: View {
  enum ChatListItemType {
    case chat(Chat, spaceName: String?)
    case user(UserInfo, chat: Chat?)
  }

  var type: ChatListItemType
  var dialog: Dialog?
  var lastMessage: Message?
  var lastMessageSender: UserInfo?
  var embeddedLastMessage: EmbeddedMessage? = nil
  var showsPinnedIndicator: Bool = true

  // fonts
  static var titleFont: Font = .system(size: 17.0).weight(.regular)
  static var subtitleFont: Font = .system(size: 17.0).weight(.regular)
  static var tertiaryFont: Font = .system(size: 15.0).weight(.regular)
  static var unreadCountFont: Font = .system(size: 15.0).weight(.regular)

  // sizes
  static var avatarSize: CGFloat = 56
  static var avatarAndContentSpacing: CGFloat = 12
  static var verticalPadding: CGFloat = 10
  static var horizontalPadding: CGFloat = 16

  // colors
  static var titleColor: Color = .primary
  static var subtitleColor: Color = .secondary
  static var tertiaryColor: some ShapeStyle { .tertiary }
  static var unreadCountColor: Color = .white
  static var unreadCircleColor: Color = .init(.systemGray2)

  private var resolvedLastMessage: Message? { embeddedLastMessage?.message ?? lastMessage }
  private var resolvedLastMessageSender: UserInfo? {
    embeddedLastMessage?.senderInfo ?? lastMessageSender
  }

  private var translatedLastMessageText: String? { embeddedLastMessage?.displayTextForLastMessage }

  var lastMessageText: String {
    translatedLastMessageText ?? resolvedLastMessage?.stringRepresentationWithEmoji ?? " "
  }

  var unreadCount: Int? {
    if let unreadCount = dialog?.unreadCount, unreadCount > 0 {
      unreadCount
    } else {
      nil
    }
  }

  private var hasUnreadMark: Bool {
    dialog?.unreadMark == true
  }

  private var isPinned: Bool {
    dialog?.pinned == true
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      avatarView
      VStack(alignment: .leading, spacing: 0) {
        titleView
        subTitleView
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: 56)
    // .listRowInsets(EdgeInsets(
    //   top: Self.verticalPadding,
    //   leading: Self.horizontalPadding,
    //   bottom: Self.verticalPadding,
    //   trailing: Self.horizontalPadding
    // ))
  }

  @ViewBuilder
  var avatarView: some View {
    VStack(alignment: .leading, spacing: 0) {
      switch type {
        case let .chat(chat, _):
          Circle()
            .fill(
              Color(.systemGray6)
            )
            .overlay {
              Text(chat.emoji ?? "💬")
                .font(.system(size: Self.avatarSize * 0.55, weight: .regular))
                .foregroundColor(.secondary)
            }
            .frame(width: Self.avatarSize, height: Self.avatarSize)

        case let .user(userInfo, _):
          UserAvatar(userInfo: userInfo, size: Self.avatarSize)
            .frame(width: Self.avatarSize, height: Self.avatarSize)
      }
    }
  }

  @ViewBuilder
  var titleView: some View {
    switch type {
      case let .chat(chat, spaceName):
        HStack(spacing: 0) {
          Text(chat.title ?? "Unknown Chat")
            .font(Self.titleFont)
            .foregroundColor(Self.titleColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
          if let spaceName {
            Text(spaceName)
              .font(Self.tertiaryFont)
              .foregroundStyle(Self.tertiaryColor)
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
      case let .user(userInfo, _):
        HStack(spacing: 0) {
          Text(userInfo.user.displayName)
            .font(Self.titleFont)
            .foregroundColor(Self.titleColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)

          Text(resolvedLastMessage?.date.formatted() ?? "")
            .font(Self.tertiaryFont)
            .foregroundStyle(Self.tertiaryColor)
            .lineLimit(1)
            .truncationMode(.tail)
        }
    }
  }

  @ViewBuilder
  var subTitleView: some View {
    switch type {
      case .chat:
        HStack(alignment: .top, spacing: 0) {
          if resolvedLastMessage != nil {
            Text("\(resolvedLastMessageSender?.user.shortDisplayName ?? ""): \(lastMessageText)")
              .font(Self.subtitleFont)
              .foregroundColor(Self.subtitleColor)
              .lineLimit(2)
              .truncationMode(.tail)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            Text(" ")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          unreadCountView
        }
//        .animation(.easeInOut, value: unreadCount)
      case .user:
        HStack(alignment: .top, spacing: 0) {
          if resolvedLastMessage != nil {
            Text("\(lastMessageText)")
              .font(Self.subtitleFont)
              .foregroundColor(Self.subtitleColor)
              .lineLimit(2)
              .truncationMode(.tail)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            Text(" ")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          unreadCountView
        }
//        .animation(.easeInOut, value: unreadCount)
    }
  }

  @ViewBuilder
  var unreadCountView: some View {
    if let unreadCount {
      Text(String(unreadCount))
        .font(Self.unreadCountFont)
        .foregroundColor(Self.unreadCountColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(minWidth: 21, alignment: .center)
        .background(Self.unreadCircleColor)
        .cornerRadius(12)
        .padding(.top, 14)
    } else if hasUnreadMark {
      Circle()
        .fill(Self.unreadCircleColor)
        .frame(width: 10, height: 10)
        .padding(.top, 18)
    } else if isPinned && showsPinnedIndicator {
      Image(systemName: "pin.fill")
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(.secondary)
        .padding(.top, 18)
    }
  }
}
