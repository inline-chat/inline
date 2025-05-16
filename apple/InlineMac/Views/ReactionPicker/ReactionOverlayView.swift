import Auth
import InlineKit
import SwiftUI

struct ReactionOverlayView: View {
  let fullMessage: FullMessage
  let onDismiss: () -> Void

  // Common emoji reactions - doubled the amount
  static let defaultReactions = [
    "🥹",
    "❤️",
    "🫡",
    "👍",
    "👎",
    "💯",
    "😂",
    "✔️",
    "🎉",
    "🔥",
    "👏",
    "🙏",
    "🤔",
    "😮",
    "😢",
    "😡",
  ]

  // State for hover and animation
  @State private var isHovered: [String: Bool] = [:]
  @State private var appearScale: CGFloat = 0.5
  @State private var appearOpacity: Double = 0

  private let pageWidth: CGFloat = 280 // Width of one page of reactions

  private func handleReactionSelected(_ emoji: String) {
    // Check if user already reacted with this emoji
    let currentUserId = Auth.shared.getCurrentUserId() ?? 0
    let hasReaction = fullMessage.reactions.contains {
      $0.emoji == emoji && $0.userId == currentUserId
    }

    if hasReaction {
      // Remove reaction
      Transactions.shared.mutate(transaction: .deleteReaction(.init(
        message: fullMessage.message,
        emoji: emoji,
        peerId: fullMessage.message.peerId,
        chatId: fullMessage.message.chatId
      )))
    } else {
      // Add reaction
      Transactions.shared.mutate(transaction: .addReaction(.init(
        message: fullMessage.message,
        emoji: emoji,
        userId: currentUserId,
        peerId: fullMessage.message.peerId
      )))
    }

    // Dismiss the overlay
    onDismiss()
  }

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 2) {
        ForEach(Self.defaultReactions, id: \.self) { emoji in
          Button(action: {
            handleReactionSelected(emoji)
          }) {
            Text(emoji)
              .font(.system(size: 22))
          }
          .buttonStyle(.plain)
          .padding(4)
          .background(
            Circle()
              .fill(Color(NSColor.windowBackgroundColor).opacity(isHovered[emoji] == true ? 0.6 : 0))
              .animation(.easeOut(duration: 0.15), value: isHovered[emoji])
          )
          .scaleEffect(isHovered[emoji] == true ? 1.1 : 1.0)
          .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isHovered[emoji])
          .onHover { hovering in
            isHovered[emoji] = hovering
          }
        }
      }
      .padding(.vertical, 2)
      .padding(.horizontal, 6)
    }
    .background(
      RoundedRectangle(cornerRadius: 20)
        .fill(.ultraThinMaterial)
        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
    )
    .frame(width: pageWidth, height: 50)
    .scaleEffect(appearScale)
    .opacity(appearOpacity)
    .onAppear {
      withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
        appearScale = 1.0
        appearOpacity = 1.0
      }
    }
    .padding(5)
  }
}
