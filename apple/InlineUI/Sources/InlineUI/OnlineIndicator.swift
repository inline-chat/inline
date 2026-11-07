import InlineKit
import SwiftUI

public extension View {
  /// A green dot on the bottom-trailing edge of a circular avatar, cut out of
  /// the avatar so it reads on any row background, including selection.
  func onlineIndicator(_ isOnline: Bool, avatarSize: CGFloat) -> some View {
    modifier(OnlineIndicatorModifier(isOnline: isOnline, avatarSize: avatarSize))
  }

  /// The online dot for a bot. People's presence is not shown.
  func botOnlineIndicator(_ user: User?, avatarSize: CGFloat) -> some View {
    onlineIndicator(user.map(BotOnlineStatus.isOnline) ?? false, avatarSize: avatarSize)
  }
}

private struct OnlineIndicatorModifier: ViewModifier {
  let isOnline: Bool
  let avatarSize: CGFloat

  // Sized so the dot's center sits on the avatar's circle at 45°.
  private var dot: CGFloat { max(6, (avatarSize * 0.28).rounded()) }
  private var gap: CGFloat { max(1.5, (avatarSize * 0.05).rounded()) }

  func body(content: Content) -> some View {
    if isOnline {
      content
        .mask {
          Rectangle()
            .overlay(alignment: .bottomTrailing) {
              Circle()
                .frame(width: dot + gap * 2, height: dot + gap * 2)
                .offset(x: gap, y: gap)
                .blendMode(.destinationOut)
            }
            .compositingGroup()
        }
        .overlay(alignment: .bottomTrailing) {
          Circle()
            .fill(Color.green)
            .frame(width: dot, height: dot)
        }
        .accessibilityValue("online")
    } else {
      content
    }
  }
}
