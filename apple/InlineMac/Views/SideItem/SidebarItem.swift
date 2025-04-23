import InlineKit
import InlineUI
import SwiftUI

struct SidebarItem: View {
  // MARK: - Types

  enum SidebarItemType {
    case chat(Chat)
    case user(UserInfo, chat: Chat?)
    case space(Space)
  }

  // MARK: - Props

  var type: SidebarItemType
  var dialog: Dialog?
  var lastMessage: Message?
  var selected: Bool = false
  var onPress: (() -> Void)?

  // MARK: - Constants

  static var avatarSize: CGFloat = 48
  static var titleFont: Font = .body.weight(.medium)
  static var subtitleFont: Font = .system(size: 12.0)
  static var subtitleColor: Color = .secondary
  static var height: CGFloat = 60
  static var verticalPadding: CGFloat = (Self.height - Self.avatarSize) / 2
  static var gutterWidth: CGFloat = Theme.sidebarItemInnerSpacing
  static var avatarAndContentSpacing: CGFloat = 8
  static var radius: CGFloat = 10

  // MARK: - State

  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered: Bool = false

  // MARK: - Views

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      gutter
      avatar
      content
      Spacer()
    }
    .padding(.vertical, Self.verticalPadding)
    .frame(height: Self.height)
    .background(background)
    .onHover { hovering in
      isHovered = hovering
    }
    .onTapGesture {
      onPress?()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(
      .horizontal,
      -Theme.sidebarNativeDefaultEdgeInsets +
        Theme.sidebarItemOuterSpacing
    )
  }

  @ViewBuilder
  var avatar: some View {
    switch type {
      case let .chat(chat):
        ChatIcon(peer: .chat(chat), size: Self.avatarSize)
      case let .user(userInfo, _):
        UserAvatar(userInfo: userInfo, size: Self.avatarSize)
      case let .space(space):
        SpaceAvatar(space: space, size: Self.avatarSize)
    }
  }

  @ViewBuilder
  var content: some View {
    VStack(alignment: .leading, spacing: 0) {
      nameView
      lastMessageView
    }
    .padding(.leading, Self.avatarAndContentSpacing)
  }

  @ViewBuilder
  var nameView: some View {
    Text(title)
      .font(Self.titleFont)
      .foregroundColor(.primary)
      .lineLimit(1)
      .truncationMode(.tail)
      .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder
  var lastMessageView: some View {
    Text(lastMessageText)
      .font(Self.subtitleFont)
      .foregroundColor(Self.subtitleColor)
      .lineLimit(2)
      .truncationMode(.tail)
      .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder
  var gutter: some View {
    HStack(spacing: 0) {
      unreadIndicator
    }
    .frame(width: Self.gutterWidth, height: Self.avatarSize)
  }

  @ViewBuilder
  var unreadIndicator: some View {
    if unreadCount > 0 {
      Circle()
        .fill(Color.accentColor)
        .frame(width: 5, height: 5)
    }
  }

  @ViewBuilder
  var background: some View {
    RoundedRectangle(cornerRadius: Self.radius)
      .fill(
        selected ? selectedBackgroundColor :
          isHovered ? Color.gray.opacity(0.1) :
          Color.clear
      )
      .shadow(
        color:
        selected ? Color.black.opacity(0.1) :
          Color.clear,
        radius: 1,
        x: 0,
        y: 1
      )
      .animation(.fastFeedback, value: isHovered)
  }

  // MARK: - Computed Properties

  var unreadCount: Int { dialog?.unreadCount ?? 0 }

  var chat: Chat? {
    switch type {
      case let .chat(chat):
        chat
      case let .user(_, chat):
        chat
      default:
        nil
    }
  }

  var user: User? {
    switch type {
      case let .user(userInfo, _):
        userInfo.user
      default:
        nil
    }
  }

  var title: String {
    switch type {
      case let .chat(chat):
        chat.title ?? ""

      case let .user(userInfo, _):
        userInfo.user.firstName ??
          userInfo.user.lastName ??
          userInfo.user.username ??
          userInfo.user.email ?? ""

      case let .space(space):
        space.name
    }
  }

  var lastMessageText: String {
    lastMessage?.stringRepresentationWithEmoji ?? " "
  }

  var selectedBackgroundColor: Color {
    colorScheme == .dark ? Color(.controlBackgroundColor) : .white.opacity(0.94)
  }

  // MARK: - Private Methods

  // TODO...
}

// MARK: - Preview

#if DEBUG
#Preview {
  var dialogWithUnread: Dialog {
    var dialog = Dialog(optimisticForUserId: User.previewUserId)
    dialog.unreadCount = 1
    return dialog
  }

  List {
    // Only name
    Section("only name") {
      SidebarItem(
        type: .user(UserInfo.preview, chat: nil),
        dialog: nil,
        selected: false
      )
    }

    // With unread
    Section("with unread") {
      SidebarItem(
        type: .user(UserInfo.preview, chat: nil),
        dialog: dialogWithUnread,

        selected: false
      )
    }

    Section("with last message") {
      SidebarItem(
        type: .user(UserInfo.preview, chat: nil),
        dialog: dialogWithUnread,
        lastMessage: Message.preview,
        selected: false
      )
    }

    Section("selected") {
      SidebarItem(
        type: .user(UserInfo.preview, chat: nil),
        dialog: nil,
        lastMessage: Message.preview,
        selected: true
      )
    }

    Section("thread") {
      SidebarItem(
        type: .chat(Chat.preview),
        dialog: nil,
        lastMessage: Message.preview,
        selected: false
      )
    }
  }
  .listStyle(.sidebar)
  .previewsEnvironmentForMac(.populated)
  .frame(width: 300, height: 800)
}
#endif
