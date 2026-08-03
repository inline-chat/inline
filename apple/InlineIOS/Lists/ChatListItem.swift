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

  enum RowStyle {
    case standard
    case prototypeCompact
    case prototypeWithPreview
    case prototypeLarge
  }

  var type: ChatListItemType
  var dialog: Dialog?
  var lastMessage: Message?
  var lastMessageSender: UserInfo?
  var embeddedLastMessage: EmbeddedMessage?
  var showsPinnedIndicator: Bool = true
  var displayMode: DisplayMode = .twoLineLastMessage
  var rowStyle: RowStyle = .standard

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
    switch rowStyle {
    case .prototypeCompact:
      return 35
    case .prototypeWithPreview:
      return 52
    case .prototypeLarge:
      return 66
    case .standard:
      break
    }

    switch displayMode {
    case .twoLineLastMessage:
      return 66
    case .oneLineLastMessage:
      return 58
    case .minimal:
      return 50
    }
  }

  private var avatarSize: CGFloat {
    switch rowStyle {
    case .prototypeCompact:
      return 34
    case .prototypeWithPreview:
      return 44
    case .prototypeLarge:
      return 56
    case .standard:
      break
    }

    switch displayMode {
    case .twoLineLastMessage:
      return 56
    case .oneLineLastMessage:
      return 50
    case .minimal:
      return 40
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
    if rowStyle == .prototypeWithPreview {
      return 1
    }

    switch displayMode {
    case .twoLineLastMessage:
      return 2
    case .oneLineLastMessage, .minimal:
      return 1
    }
  }

  private var subtitleReservesSpace: Bool {
    (rowStyle == .standard || rowStyle == .prototypeLarge)
      && displayMode == .twoLineLastMessage
  }

  private var rowAlignment: VerticalAlignment {
    displayMode == .minimal ? .center : .top
  }

  private var showsLastMessage: Bool {
    displayMode != .minimal
  }

  private var showsUnreadInTitle: Bool {
    displayMode == .minimal && !usesCenteredUnreadAccessory
  }

  private var usesCenteredUnreadAccessory: Bool {
    rowStyle != .standard
  }

  private var showsLeadingUnreadDot: Bool {
    usesCenteredUnreadAccessory && unreadCount == nil && hasUnreadMark
  }

  private var showsTrailingUnreadCount: Bool {
    usesCenteredUnreadAccessory && unreadCount != nil
  }

  private var hasProminentUnread: Bool {
    if dialog?.peerUserId != nil || dialog?.isFollowingReplyThread == true {
      return true
    }

    switch type {
    case .user:
      return true
    case let .chat(chat, _):
      return chat.type == .privateChat
    }
  }

  private var titleFont: Font {
    switch rowStyle {
    case .standard:
      Self.titleFont
    case .prototypeCompact:
      .system(size: 18, weight: .medium)
    case .prototypeWithPreview:
      .system(size: 16, weight: .medium)
    case .prototypeLarge:
      .system(size: 16, weight: .medium)
    }
  }

  private var subtitleFont: Font {
    switch rowStyle {
    case .standard, .prototypeLarge:
      Self.subtitleFont
    case .prototypeCompact, .prototypeWithPreview:
      .system(size: 14, weight: .regular)
    }
  }

  private var avatarAndContentSpacing: CGFloat {
    switch rowStyle {
    case .standard, .prototypeLarge:
      Self.avatarAndContentSpacing
    case .prototypeCompact, .prototypeWithPreview:
      10
    }
  }

  var body: some View {
    ZStack(alignment: .leading) {
      if showsLeadingUnreadDot {
        unreadCountView
      }

      HStack(alignment: rowAlignment, spacing: avatarAndContentSpacing) {
        avatarView
        VStack(alignment: .leading, spacing: showsLastMessage ? 2 : 0) {
          titleView
          if showsLastMessage {
            subTitleView
          }
        }
        .padding(.top, textTopOffset)
        .frame(maxWidth: .infinity, alignment: .leading)

        if showsTrailingUnreadCount {
          unreadCountView
            .padding(.leading, 8)
            .frame(height: rowHeight, alignment: .center)
        }
      }
      .padding(.leading, usesCenteredUnreadAccessory ? 10 : 0)
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
            shape: rowStyle == .prototypeCompact ? .none : .circle,
            symbolColor: rowStyle == .prototypeCompact ? .primary : .secondary
          )
          .frame(width: avatarSize, height: avatarSize)

        case let .user(userInfo, _):
          UserAvatar(userInfo: userInfo, size: avatarSize)
            .frame(width: avatarSize, height: avatarSize)
      }
    }
  }

  private var threadIconSize: ThreadIconSize {
    switch displayMode {
    case .minimal:
      return rowStyle == .prototypeCompact
        ? .compact((avatarSize + 2) * 0.9)
        : .regular(avatarSize)
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
            .font(titleFont)
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
            }
            ChatListPinnedIndicator(isVisible: isPinned && showsPinnedIndicator)
            if showsUnreadInTitle {
              unreadCountView
                .padding(.leading, 8)
            }
          }
        }
      case let .user(userInfo, _):
        HStack(spacing: 0) {
          Text(userInfo.user.needsDisplayNameFetch ? "Loading..." : userInfo.user.displayName)
            .font(titleFont)
            .foregroundColor(Self.titleColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
          ChatListPinnedIndicator(isVisible: isPinned && showsPinnedIndicator)
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
              .font(subtitleFont)
              .foregroundColor(Self.subtitleColor)
              .lineLimit(subtitleLineLimit, reservesSpace: subtitleReservesSpace)
              .truncationMode(.tail)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            Text(" ")
              .font(subtitleFont)
              .foregroundColor(Self.subtitleColor)
              .lineLimit(subtitleLineLimit, reservesSpace: subtitleReservesSpace)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          if !usesCenteredUnreadAccessory {
            unreadCountView
          }
        }
//        .animation(.easeInOut, value: unreadCount)
      case .user:
        HStack(alignment: .top, spacing: 0) {
          if resolvedLastMessage != nil {
            Text("\(lastMessageText)")
              .font(subtitleFont)
              .foregroundColor(Self.subtitleColor)
              .lineLimit(subtitleLineLimit, reservesSpace: subtitleReservesSpace)
              .truncationMode(.tail)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            Text(" ")
              .font(subtitleFont)
              .foregroundColor(Self.subtitleColor)
              .lineLimit(subtitleLineLimit, reservesSpace: subtitleReservesSpace)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          if !usesCenteredUnreadAccessory {
            unreadCountView
          }
        }
//        .animation(.easeInOut, value: unreadCount)
    }
  }

  @ViewBuilder
  var unreadCountView: some View {
    if usesCenteredUnreadAccessory {
      if let unreadCount {
        Text(String(unreadCount))
          .font(.system(size: 13, weight: .semibold).monospacedDigit())
          .foregroundStyle(hasProminentUnread ? Color.white : Color.primary.opacity(0.76))
          .lineLimit(1)
          .contentTransition(.numericText())
          .padding(.horizontal, 6)
          .frame(minWidth: 20, minHeight: 20)
          .fixedSize(horizontal: true, vertical: false)
          .background(
            Capsule().fill(hasProminentUnread ? Color.accentColor : Color(.secondarySystemFill))
          )
      } else if hasUnreadMark {
        Circle()
          .fill(hasProminentUnread ? Color.accentColor : Color.secondary)
          .frame(width: 7, height: 7)
      }
    } else {
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
}

private struct ChatListPinnedIndicator: View {
  let isVisible: Bool

  var body: some View {
    if isVisible {
      Image(systemName: "pin.fill")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.tertiary)
        .padding(.leading, 4)
    }
  }
}
