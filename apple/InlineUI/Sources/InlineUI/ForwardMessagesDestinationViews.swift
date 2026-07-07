import InlineKit
import SwiftUI

struct ForwardMessagesAvatarView: View, Equatable {
  enum Shape: Equatable {
    case circle
    case roundedSquare

    var threadIconShape: ThreadIconShape {
      switch self {
      case .circle:
        .circle
      case .roundedSquare:
        .roundedSquare
      }
    }
  }

  let avatar: ForwardMessagesDestination.Avatar
  let size: CGFloat
  var shape: Shape = .circle

  nonisolated static func == (lhs: ForwardMessagesAvatarView, rhs: ForwardMessagesAvatarView) -> Bool {
    lhs.avatar == rhs.avatar
      && lhs.size == rhs.size
      && lhs.shape == rhs.shape
  }

  var body: some View {
    Group {
      switch avatar {
      case let .user(userInfo):
        UserAvatar(userInfo: userInfo, size: size)
      case let .chat(title, emoji):
        ThreadIconView(
          ThreadIconDescriptor(emoji: emoji, title: title, accessibilityLabel: title),
          size: .compact(size),
          shape: shape.threadIconShape
        )
      case .fallback:
        ThreadIconView(
          ThreadIconDescriptor(emoji: nil, title: "Chat", accessibilityLabel: "Chat"),
          size: .compact(size),
          shape: shape.threadIconShape
        )
      }
    }
    .frame(width: size, height: size)
    .fixedSize()
  }
}

struct ForwardMessagesUnreadDot: View {
  let size: CGFloat

  var body: some View {
    Circle()
      .fill(Color.accentColor)
      .frame(width: size, height: size)
      .accessibilityLabel("Unread")
  }
}
