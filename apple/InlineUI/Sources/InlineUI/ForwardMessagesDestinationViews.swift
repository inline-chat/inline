import InlineKit
import SwiftUI

struct ForwardMessagesAvatarView: View, Equatable {
  enum Shape: Equatable {
    case circle
    case roundedSquare
  }

  let avatar: ForwardMessagesDestination.Avatar
  let size: CGFloat
  var shape: Shape = .circle

  @Environment(\.colorScheme) private var colorScheme

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
          chatAvatar(title: title, emoji: normalizedEmoji(emoji))
        case .fallback:
          chatAvatar(title: "Chat", emoji: nil)
      }
    }
    .frame(width: size, height: size)
    .fixedSize()
  }

  private func chatAvatar(title: String, emoji: String?) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .fill(chatBackground)
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(chatBorder, lineWidth: 0.5)
      }
      .overlay {
        if let emoji {
          Text(emoji)
            .font(.system(size: size * 0.55, weight: .regular))
        } else {
          Image(systemName: "number")
            .font(.system(size: size * 0.46, weight: .regular))
            .foregroundStyle(.secondary)
        }
      }
      .clipShape(clipShape)
      .accessibilityHidden(true)
  }

  private var cornerRadius: CGFloat {
    switch shape {
      case .circle:
        size / 2
      case .roundedSquare:
        size * 0.28
    }
  }

  private var chatBackground: LinearGradient {
    let top = colorScheme == .dark
      ? Color.white.opacity(0.12)
      : Color.black.opacity(0.06)
    let bottom = colorScheme == .dark
      ? Color.white.opacity(0.08)
      : Color.black.opacity(0.035)

    return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
  }

  private var chatBorder: Color {
    colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06)
  }

  private var clipShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
  }

  private func normalizedEmoji(_ emoji: String?) -> String? {
    guard let emoji else { return nil }
    let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
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
