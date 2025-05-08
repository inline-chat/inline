import InlineKit
import InlineUI
import SwiftUI

struct MemberItem: View {
  // MARK: - Props

  var member: FullMemberItem
  var selected: Bool = false
  var onPress: (() -> Void)?

  private let isCurrentUser: Bool

  // MARK: - Constants

  static var avatarSize: CGFloat = 32
  static var titleFont: Font = .system(size: 13.0).weight(.regular)
  static var subtitleFont: Font = .system(size: 11.0)
  static var subtitleColor: Color = .secondary.opacity(0.9)
  static var height: CGFloat = 38
  static var verticalPadding: CGFloat = (Self.height - Self.avatarSize) / 2
  static var gutterWidth: CGFloat = Theme.sidebarItemInnerSpacing
  static var avatarAndContentSpacing: CGFloat = 8
  static var radius: CGFloat = 10

  // MARK: - State

  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered: Bool = false

  // MARK: - Initializer

  init(
    member: FullMemberItem,
    selected: Bool = false,
    onPress: (() -> Void)? = nil
  ) {
    self.member = member
    self.selected = selected
    self.onPress = onPress

    isCurrentUser = member.userInfo.user.isCurrentUser()
  }

  // MARK: - Views

  var body: some View {
    HStack(alignment: .center, spacing: 0) {
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
    // TODO:
    // .swipeActions(edge: .trailing, allowsFullSwipe: true) {
    // }
  }

  @ViewBuilder
  var avatar: some View {
    UserAvatar(userInfo: member.userInfo, size: Self.avatarSize)
  }

  @ViewBuilder
  var content: some View {
    VStack(alignment: .leading, spacing: 0) {
      nameView
      subtitleView
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, Self.avatarAndContentSpacing)
    // doesn't work for some reason
    // .animation(.fastFeedback, value: hasComposeAction)
  }

  @ViewBuilder
  var nameView: some View {
    (
      Text(title)
        + (
          isCurrentUser ?
            Text(" (You)").foregroundColor(Self.subtitleColor)
            : Text("")
        )
    )
    .font(Self.titleFont)
    .foregroundColor(.primary)
    .lineLimit(1)
    .truncationMode(.tail)
    .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder
  var subtitleView: some View {
    if !subtitleText.isEmpty {
      Text(subtitleText)
        .font(Self.subtitleFont)
        .foregroundColor(Self.subtitleColor)
        .lineLimit(1)
        .truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  var gutter: some View {
    HStack(spacing: 0) {
      // unreadIndicator
    }
    .frame(width: Self.gutterWidth, height: Self.avatarSize)
  }

//  @ViewBuilder
//  var unreadIndicator: some View {
//    if unreadCount > 0 {
//      Circle()
//        .fill(Color.accentColor)
//        .frame(width: 5, height: 5)
//    }
//  }

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

  var userInfo: UserInfo {
    member.userInfo
  }

  var user: User {
    userInfo.user
  }

  var peerId: Peer {
    .user(id: user.id)
  }

  var title: String {
    user.displayName
  }

  var subtitleText: String {
    if user.online == true {
      "online"
    } else if let lastOnline = user.lastOnline {
      formatLastSeenTime(lastOnline)
    } else {
      ""
    }
  }

  var selectedBackgroundColor: Color {
    // White style
    // colorScheme == .dark ? Color(.controlBackgroundColor) : .white.opacity(0.94)

    // Gray style
    colorScheme == .dark ? .white.opacity(0.1) : .gray.opacity(0.1)
  }

  // MARK: - Private Methods

  private static let lastSeenFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

  private func formatLastSeenTime(_ date: Date) -> String {
    let diffSeconds = Date().timeIntervalSince(date)

    if diffSeconds < 59 {
      return "just now"
    }

    return "last seen \(Self.lastSeenFormatter.localizedString(for: date, relativeTo: Date()))"
  }

  // TODO...
}

// MARK: - Preview

// TODO:
// #if DEBUG
// #Preview {
//  MemberItem(
//    member: .init(
//
//      lastMessage: nil,
//      unreadCount: 0
//    ),
//    selected: false,
//    onPress: {}
//  )
//  .listStyle(.sidebar)
//  .previewsEnvironmentForMac(.populated)
//  .frame(width: 300, height: 800)
// }
// #endif
