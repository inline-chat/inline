import InlineKit
import InlineUI
import SwiftUI

struct ChatListItem: View {
  enum ChatListItemType {
    case chat(Chat, spaceName: String?)
    case user(UserInfo, chat: Chat?)
  }

  enum DisplayMode {
    case twoLineLastMessage
    case oneLineLastMessage
    case minimal
  }

  var type: ChatListItemType
  var dialog: Dialog?
  var lastMessage: Message?
  var lastMessageSender: UserInfo?
  var embeddedLastMessage: EmbeddedMessage? = nil
  var showsPinnedIndicator: Bool = true
  var displayMode: DisplayMode = .twoLineLastMessage

  // fonts
  static var titleFont: Font = .system(size: 16.0, weight: .regular, design: .default)
  static var subtitleFont: Font = .system(size: 15.0).weight(.regular)
  static var tertiaryFont: Font = .system(size: 14.0, weight: .regular, design: .default)
  static var unreadCountFont: Font = .system(size: 14.0, weight: .regular, design: .default)

  // sizes
  static var avatarAndContentSpacing: CGFloat = 12
  static var textTopOffset: CGFloat = 3
  // static var verticalPadding: CGFloat = 0
  // static var horizontalPadding: CGFloat = 16

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

  private var rowHeight: CGFloat {
    switch displayMode {
    case .twoLineLastMessage:
      66
    case .oneLineLastMessage:
      58
    case .minimal:
      50
    }
  }

  private var avatarSize: CGFloat {
    switch displayMode {
    case .twoLineLastMessage:
      56
    case .oneLineLastMessage:
      50
    case .minimal:
      40
    }
  }

  private var textTopOffset: CGFloat {
    switch displayMode {
    case .twoLineLastMessage:
      Self.textTopOffset
    case .oneLineLastMessage:
      1
    case .minimal:
      0
    }
  }

  private var subtitleLineLimit: Int {
    switch displayMode {
    case .twoLineLastMessage:
      2
    case .oneLineLastMessage, .minimal:
      1
    }
  }

  private var subtitleReservesSpace: Bool {
    displayMode == .twoLineLastMessage
  }

  private var rowAlignment: VerticalAlignment {
    displayMode == .minimal ? .center : .top
  }

  private var showsLastMessage: Bool {
    displayMode != .minimal
  }

  private var showsUnreadInTitle: Bool {
    displayMode == .minimal
  }

  var body: some View {
    HStack(alignment: rowAlignment, spacing: Self.avatarAndContentSpacing) {
      avatarView
      VStack(alignment: .leading, spacing: showsLastMessage ? 2 : 0) {
        titleView
        if showsLastMessage {
          subTitleView
        }
      }
      .padding(.top, textTopOffset)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: rowHeight)
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
          ThreadIconView(
            ThreadIconDescriptor(chat: chat),
            size: threadIconSize,
            shape: .circle
          )

        case let .user(userInfo, _):
          UserAvatar(userInfo: userInfo, size: avatarSize)
            .frame(width: avatarSize, height: avatarSize)
      }
    }
  }

  private var threadIconSize: ThreadIconSize {
    switch displayMode {
    case .minimal:
      return .regular(avatarSize)
    case .twoLineLastMessage, .oneLineLastMessage:
      return .large(avatarSize)
    }
  }

  @ViewBuilder
  var titleView: some View {
    switch type {
      case let .chat(chat, spaceName):
        HStack(spacing: 0) {
          Text(chat.humanReadableTitle ?? "Unknown Chat")
            .font(Self.titleFont)
            .foregroundColor(Self.titleColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
          HStack(spacing: 0) {
            if let spaceName {
              Text(spaceName)
                .font(Self.tertiaryFont)
                .foregroundStyle(Self.tertiaryColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .monospacedDigit()
              if isPinned, showsPinnedIndicator {
                Image(systemName: "pin.fill")
                  .font(.system(size: 11, weight: .semibold))
                  .foregroundColor(.secondary)
                  .padding(.leading, 4)
              }
            }
            if showsUnreadInTitle {
              unreadCountView
                .padding(.leading, 8)
            }
          }
        }
      case let .user(userInfo, _):
        HStack(spacing: 0) {
          Text(userInfo.user.needsDisplayNameFetch ? "Loading..." : userInfo.user.displayName)
            .font(Self.titleFont)
            .foregroundColor(Self.titleColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
          if isPinned, showsPinnedIndicator {
            Image(systemName: "pin.fill")
              .font(.system(size: 11, weight: .semibold))
              .foregroundColor(.secondary)
          }
          if showsUnreadInTitle {
            unreadCountView
              .padding(.leading, 8)
          }
          // Text(resolvedLastMessage?.date.formatted() ?? "")
          //   .font(Self.tertiaryFont)
          //   .foregroundStyle(Self.tertiaryColor)
          //   .lineLimit(1)
          //   .truncationMode(.tail)
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
              .lineLimit(subtitleLineLimit, reservesSpace: subtitleReservesSpace)
              .truncationMode(.tail)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            Text(" ")
              .font(Self.subtitleFont)
              .foregroundColor(Self.subtitleColor)
              .lineLimit(subtitleLineLimit, reservesSpace: subtitleReservesSpace)
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
              .lineLimit(subtitleLineLimit, reservesSpace: subtitleReservesSpace)
              .truncationMode(.tail)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            Text(" ")
              .font(Self.subtitleFont)
              .foregroundColor(Self.subtitleColor)
              .lineLimit(subtitleLineLimit, reservesSpace: subtitleReservesSpace)
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
        .font(Self.unreadCountFont.monospacedDigit())
        .foregroundColor(Self.unreadCountColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(minWidth: 21, alignment: .center)
        .background(Self.unreadCircleColor)
        .cornerRadius(12)
    } else if hasUnreadMark {
      Circle()
        .fill(Self.unreadCircleColor)
        .frame(width: 10, height: 10)
    }
  }
}
