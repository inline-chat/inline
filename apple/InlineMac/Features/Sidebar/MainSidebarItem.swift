import InlineKit
import InlineUI
import SwiftUI

struct MainSidebarItem: View {
  // MARK: - Props

  var type: SidebarItemType
  var dialog: Dialog?
  var lastMessage: Message?
  var lastMessageSender: UserInfo?
  var selected: Bool = false
  var onPress: (() -> Void)?

  private let isCurrentUser: Bool

  // MARK: - State

  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered: Bool = false
  @State private var currentComposeAction: ApiComposeAction?

  // MARK: - Types

  enum SidebarItemType {
    case chat(Chat)
    case user(UserInfo, chat: Chat?)
  }

  // MARK: - Constants

  static var avatarSize: CGFloat = 28
  static var titleFont: Font = .system(size: 13.0).weight(.regular)
  static var subtitleFont: Font = .system(size: 12.0)
  static var subtitleColor: Color = .secondary.opacity(0.9)
  static var height: CGFloat = 34
  static var verticalPadding: CGFloat = (Self.height - Self.avatarSize) / 2
  static var avatarAndContentSpacing: CGFloat = 8
  static var contentSpacing: CGFloat = 8
  static var sidePadding: CGFloat = 6
  static var radius: CGFloat = 8

  // MARK: - Initializer

  init(
    type: SidebarItemType,
    dialog: Dialog?,
    lastMessage: Message? = nil,
    lastMessageSender: UserInfo? = nil,
    selected: Bool = false,
    onPress: (() -> Void)? = nil
  ) {
    self.type = type
    self.dialog = dialog
    self.lastMessage = lastMessage
    self.lastMessageSender = lastMessageSender
    self.selected = selected
    self.onPress = onPress

    if case let .user(userInfo, _) = type {
      isCurrentUser = userInfo.user.isCurrentUser()
    } else {
      isCurrentUser = false
    }
  }

  // MARK: - Views

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      avatar
      content // fills the space
      badge
    }
    .padding(.vertical, Self.verticalPadding)
    .padding(.horizontal, Self.sidePadding)
    .frame(height: Self.height)
    .background(background)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.bottom, 1)
    // Outer padding for separating item from sidebar edges
    // .padding(
    //   .horizontal,
    //   -Theme.sidebarNativeDefaultEdgeInsets +
    //     Theme.sidebarItemOuterSpacing
    // )

    // Not very reliable
    .whenHovered { hovering in
      isHovered = hovering
    }

    .onTapGesture {
      onPress?()
    }

    // TODO: Move to context menu
    // .swipeActions(edge: .trailing, allowsFullSwipe: true) {
    //   Button(role: .destructive) {
    //     if let peerId {
    //       // TODO: handle space
    //       Task(priority: .userInitiated) {
    //         try await DataManager.shared.updateDialog(peerId: peerId, archived: !(dialog?.archived ?? false))
    //       }
    //     }
    //   } label: {
    //     Label("Archive", systemImage: "archivebox.fill")
    //   }
    //   .tint(.purple)

    //   Button {
    //     if let peerId {
    //       Task(priority: .userInitiated) {
    //         try await DataManager.shared.updateDialog(peerId: peerId, pinned: !pinned)
    //       }
    //     }
    //   } label: {
    //     Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash.fill" : "pin.fill")
    //   }.tint(.orange)
    // }
  }

  @ViewBuilder
  var avatar: some View {
    switch type {
      case let .chat(chat):
        ChatIcon(peer: .chat(chat), size: Self.avatarSize)
      case let .user(userInfo, _):
        if isCurrentUser {
          InitialsCircle(name: userFullName, size: Self.avatarSize, symbol: "bookmark.fill")
        } else {
          UserAvatar(userInfo: userInfo, size: Self.avatarSize)
        }
    }
  }

  @ViewBuilder
  var content: some View {
    VStack(alignment: .leading, spacing: 0) {
      nameView
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, Self.avatarAndContentSpacing)
    .padding(.top, -1)
  }

  @ViewBuilder
  var nameView: some View {
    Text(title)
      .font(Self.titleFont)
      .foregroundColor(.primary)
      .lineLimit(1)
      .truncationMode(.tail)
      .fixedSize(horizontal: false, vertical: true)
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  var badge: some View {
    HStack(spacing: 0) {
      if unreadCount > 0 {
        unreadIndicator
      } else if pinned {
        pinnedIndicator
      }
    }
    .animation(.fastFeedback, value: unreadCount > 0)
  }

  @ViewBuilder
  var unreadIndicator: some View {
    Circle()
      .fill(Color.accentColor)
      .frame(width: 5, height: 5)
  }

  @ViewBuilder
  var pinnedIndicator: some View {
    Image(systemName: "pin.fill")
      .font(.system(size: 8))
      .foregroundColor(Color.secondary.opacity(0.5))
      .frame(width: 5, height: 5)
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

  var peerId: Peer? {
    switch type {
      case let .chat(chat):
        .thread(id: chat.id)
      case let .user(userInfo, _):
        .user(id: userInfo.user.id)
      default:
        nil
    }
  }

  var userFullName: String {
    switch type {
      case let .user(userInfo, _):
        if !userInfo.user.fullName.isEmpty {
          userInfo.user.fullName
        } else {
          userInfo.user.firstName ??
            userInfo.user.lastName ??
            userInfo.user.username ??
            userInfo.user.phoneNumber ??
            userInfo.user.email ?? ""
        }
      default:
        ""
    }
  }

  var title: String {
    switch type {
      case let .chat(chat):
        chat.title ?? ""

      case let .user(userInfo, _):
        if isCurrentUser {
          "Saved Messages"
        } else {
          userInfo.user.firstName ??
            userInfo.user.lastName ??
            userInfo.user.username ??
            userInfo.user.phoneNumber ??
            userInfo.user.email ?? ""
        }

      default:
        ""
    }
  }

  var selectedBackgroundColor: Color {
    // White style
    colorScheme == .dark ? Color(.controlBackgroundColor) : .white.opacity(0.94)

    // Gray style
    // colorScheme == .dark ? .white.opacity(0.1) : .gray.opacity(0.1)
  }

  var pinned: Bool {
    dialog?.pinned ?? false
  }

  // TODO...
}

// MARK: - Preview

// #if DEBUG
// #Preview {
//   var dialogWithUnread: Dialog {
//     var dialog = Dialog(optimisticForUserId: User.previewUserId)
//     dialog.unreadCount = 1
//     return dialog
//   }

//   var pinnedDialog: Dialog {
//     var dialog = Dialog(optimisticForUserId: User.previewUserId)
//     dialog.pinned = true
//     return dialog
//   }

//   List {
//     // Only name
//     Section("only name") {
//       SidebarItem(
//         type: .user(UserInfo.preview, chat: nil),
//         dialog: nil,
//         selected: false
//       )
//     }

//     // With unread
//     Section("with unread") {
//       SidebarItem(
//         type: .user(UserInfo.preview, chat: nil),
//         dialog: dialogWithUnread,

//         selected: false
//       )
//     }

//     Section("with last message") {
//       SidebarItem(
//         type: .user(UserInfo.preview, chat: nil),
//         dialog: dialogWithUnread,
//         lastMessage: Message.preview,
//         selected: false
//       )
//     }

//     Section("pinned with last message") {
//       SidebarItem(
//         type: .user(UserInfo.preview, chat: nil),
//         dialog: pinnedDialog,
//         lastMessage: Message.preview,
//         selected: false
//       )
//     }

//     Section("selected") {
//       SidebarItem(
//         type: .user(UserInfo.preview, chat: nil),
//         dialog: nil,
//         lastMessage: Message.preview,
//         selected: true
//       )
//     }

//     Section("thread") {
//       SidebarItem(
//         type: .chat(Chat.preview, spaceName: "Space"),
//         dialog: nil,
//         lastMessage: Message.preview,
//         selected: false
//       )
//     }
//   }
//   .listStyle(.sidebar)
//   .previewsEnvironmentForMac(.populated)
//   .frame(width: 300, height: 800)
// }
// #endif
