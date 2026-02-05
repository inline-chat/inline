import InlineKit
import InlineUI
import SwiftUI

struct SidebarChatIcon: View, Equatable {
  var peer: ChatIcon.PeerType
  var size: CGFloat = 34

  static func == (lhs: SidebarChatIcon, rhs: SidebarChatIcon) -> Bool {
    lhs.peer == rhs.peer && lhs.size == rhs.size
  }

  var body: some View {
    switch peer {
      case let .chat(chat):
        ThreadIcon(emoji: normalizedEmoji(chat.emoji), size: size)
      case let .user(userInfo):
        UserAvatar(userInfo: userInfo, size: size)
      case let .savedMessage(user):
        InitialsCircle(name: user.firstName ?? user.username ?? "", size: size, symbol: "bookmark.fill")
    }
  }

  private func normalizedEmoji(_ emoji: String?) -> String? {
    guard let emoji else { return nil }
    let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

private struct ThreadIcon: View {
  let emoji: String?
  let size: CGFloat

  @Environment(\.colorScheme) private var colorScheme

  private static let lightTop = Color(.sRGB, red: 241 / 255, green: 239 / 255, blue: 239 / 255, opacity: 0.5)
  private static let lightBottom = Color(.sRGB, red: 229 / 255, green: 229 / 255, blue: 229 / 255, opacity: 0.5)
  private static let darkTop = Color(.sRGB, red: 58 / 255, green: 58 / 255, blue: 58 / 255, opacity: 0.5)
  private static let darkBottom = Color(.sRGB, red: 44 / 255, green: 44 / 255, blue: 44 / 255, opacity: 0.5)
  private static let symbolForeground = Color(.sRGB, red: 0.35, green: 0.35, blue: 0.35, opacity: 1)

  private var backgroundGradient: LinearGradient {
    let colors = colorScheme == .dark
      ? [Self.darkTop, Self.darkBottom]
      : [Self.lightTop, Self.lightBottom]

    return LinearGradient(
      colors: colors,
      startPoint: .top,
      endPoint: .bottom
    )
  }

  private var borderColor: Color {
    colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)
  }

  private var emojiPointSize: CGFloat { size * 0.5 }
  private var symbolPointSize: CGFloat { size * 0.5 }

  var body: some View {
    Circle()
      .fill(backgroundGradient)
      .overlay(
        Circle()
          .stroke(borderColor, lineWidth: 0.5)
      )
      .overlay {
        if let emoji {
          Text(emoji)
            .font(.system(size: emojiPointSize, weight: .regular))
        } else {
          Image(systemName: "number")
            .font(.system(size: symbolPointSize, weight: .medium))
            .foregroundColor(Self.symbolForeground)
        }
      }
      .frame(width: size, height: size)
      .fixedSize()
  }
}
