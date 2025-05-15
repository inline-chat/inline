import InlineKit
import InlineUI
import SwiftUI

struct SidebarItem: View {
  // MARK: - Types

  enum SidebarItemType {
    case chat(Chat, spaceName: String?)
    case user(UserInfo, chat: Chat?)
    case space(Space)
  }

  // MARK: - Props

  var type: SidebarItemType
  var dialog: Dialog?
  var lastMessage: Message?
  var lastMessageSender: UserInfo?
  var selected: Bool = false
  var onPress: (() -> Void)?

  private let isCurrentUser: Bool

  // MARK: - Constants

  static var avatarSize: CGFloat = 46
  static var titleFont: Font = .system(size: 13.0).weight(.regular)
  static var subtitleFont: Font = .system(size: 12.0)
  static var subtitleColor: Color = .secondary.opacity(0.9)
  static var tertiaryFont: Font = .system(size: 11.0)
  static var tertiaryColor: Color = .secondary.opacity(0.6)
  static var height: CGFloat = 56
  static var verticalPadding: CGFloat = (Self.height - Self.avatarSize) / 2
  static var gutterWidth: CGFloat = Theme.sidebarItemInnerSpacing
  static var avatarAndContentSpacing: CGFloat = 8
  static var radius: CGFloat = 10

  // MARK: - State

  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered: Bool = false
  @State private var currentComposeAction: ApiComposeAction?

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
      gutter
      avatar
      content
    }
    .padding(.vertical, Self.verticalPadding)
    .frame(height: Self.height)
    .background(background)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.bottom, 1)
    .padding(
      .horizontal,
      -Theme.sidebarNativeDefaultEdgeInsets +
        Theme.sidebarItemOuterSpacing
    )
    .onHover { hovering in
      isHovered = hovering
    }
    .onTapGesture {
      onPress?()
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button(role: .destructive) {
        if let peerId {
          // TODO: handle space
          Task(priority: .userInitiated) {
            try await DataManager.shared.updateDialog(peerId: peerId, archived: !(dialog?.archived ?? false))
          }
        }
      } label: {
        Label("Archive", systemImage: "archivebox.fill")
      }
      .tint(.purple)
    }

    // Listeners
    .onReceive(ComposeActions.shared.$actions, perform: onComposeActionReceive)
  }

  @ViewBuilder
  var avatar: some View {
    switch type {
      case let .chat(chat, _):
        ChatIcon(peer: .chat(chat), size: Self.avatarSize)
      case let .user(userInfo, _):
        if isCurrentUser {
          InitialsCircle(name: userFullName, size: Self.avatarSize, symbol: "bookmark.fill")
        } else {
          UserAvatar(userInfo: userInfo, size: Self.avatarSize)
        }
      case let .space(space):
        SpaceAvatar(space: space, size: Self.avatarSize)
    }
  }

  @ViewBuilder
  var content: some View {
    VStack(alignment: .leading, spacing: 0) {
      nameView

      if hasComposeAction {
        typingView
      } else {
        if showsMessageSender {
          lastMessageSenderView
        }
        lastMessageView
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, Self.avatarAndContentSpacing)
    // doesn't work for some reason
    // .animation(.fastFeedback, value: hasComposeAction)
  }

  @ViewBuilder
  var nameView: some View {
//    let text = if case let .chat(_, spaceName) = type,
//                  let spaceName
//    {
//      Text(spaceName)
//        .foregroundColor(.secondary) +
//        Text(" / ")
//        .foregroundColor(.secondary) +
//        Text(title)
//    } else {
//      Text(title)
//    }

    HStack(spacing: 1) {
      Text(title)
        .font(Self.titleFont)
        .foregroundColor(.primary)
        .lineLimit(1)
        .truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)

      Spacer()

      spaceView
    }.padding(.trailing, 8)
  }

  @ViewBuilder
  var lastMessageView: some View {
    HStack(spacing: 0) {
      // senderView
      Text(lastMessageText)
        .font(Self.subtitleFont)
        .foregroundColor(Self.subtitleColor)
        .lineLimit(showsMessageSender ? 1 : 2)
        .truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  var typingView: some View {
    if let currentComposeAction {
      Text(currentComposeAction.toHumanReadable())
        .font(Self.subtitleFont)
        .foregroundColor(Self.subtitleColor)
        .lineLimit(1)
        .truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      EmptyView()
    }
  }

  @ViewBuilder
  var spaceView: some View {
    if case let .chat(_, spaceName) = type,
       let spaceName
    {
      Text(spaceName)
        //.font(Self.subtitleFont)
        //.foregroundColor(Self.subtitleColor)
        .font(Self.tertiaryFont)
        .foregroundColor(Self.tertiaryColor)
        .lineLimit(1)
        .truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      EmptyView()
    }
  }

  @ViewBuilder
  var lastMessageSenderView: some View {
//    spaceView

    senderView

//    if let lastMessageSender {
//      HStack(spacing: 3) {
//        UserAvatar(
//          userInfo: lastMessageSender,
//          size: 12
//        )
//        Text(lastMessageSender.user.shortDisplayName)
//          .font(Self.subtitleFont)
//          .foregroundColor(Self.subtitleColor)
//          .lineLimit(1)
//          .truncationMode(.tail)
//          .fixedSize(horizontal: false, vertical: true)
//      }.padding(.top, 1)
//    } else {
//      EmptyView()
//    }
  }

  @ViewBuilder
  var senderView: some View {
    if let lastMessageSender {
      HStack(spacing: 2) {
        UserAvatar(
          userInfo: lastMessageSender,
          size: 11
        )
        Text(lastMessageSender.user.shortDisplayName)
          .font(Self.subtitleFont)
          .foregroundColor(Self.subtitleColor)
          .lineLimit(1)
          .truncationMode(.tail)
          .fixedSize(horizontal: false, vertical: true)
      }
    } else {
      EmptyView()
    }
  }

  @ViewBuilder
  var gutter: some View {
    HStack(spacing: 0) {
      unreadIndicator
    }
    .animation(.fastFeedback, value: unreadCount > 0)
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
      case let .chat(chat, _):
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
      case let .chat(chat, _):
        .thread(id: chat.id)
      case let .user(userInfo, _):
        .user(id: userInfo.user.id)
      default:
        nil
    }
  }

  var showsMessageSender: Bool {
    switch type {
      case .user:
        false
      case .space, .chat:
        true
    }
  }

  var hasComposeAction: Bool {
    currentComposeAction != nil
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
      case let .chat(chat, spaceName):
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

      case let .space(space):
        space.name
    }
  }

  var lastMessageText: String {
    lastMessage?.stringRepresentationWithEmoji ?? " "
  }

  var selectedBackgroundColor: Color {
    // White style
    // colorScheme == .dark ? Color(.controlBackgroundColor) : .white.opacity(0.94)

    // Gray style
    colorScheme == .dark ? .white.opacity(0.1) : .gray.opacity(0.1)
  }

  // MARK: - Private Methods

  private func setComposeAction() {
    guard let peerId else { return }

    currentComposeAction = ComposeActions.shared.getComposeAction(for: peerId)?.action
  }

  /// Called when the compose action changes, check if it is the same
  private func onComposeActionReceive(actions: [Peer: ComposeActionInfo]) {
    guard let peerId else { return }

    // If changed
    if actions[peerId]?.action != currentComposeAction {
      DispatchQueue.main.async {
        setComposeAction()
      }
    }
  }

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
        type: .chat(Chat.preview, spaceName: "Space"),
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
