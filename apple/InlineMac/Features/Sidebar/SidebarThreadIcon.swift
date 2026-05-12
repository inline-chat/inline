import InlineKit
import SwiftUI

struct SidebarThreadIcon: View, Equatable {
  enum IconShape: Equatable {
    case roundedSquare
    case circle
  }

  let emoji: String?
  var size: CGFloat = 20
  var shape: IconShape = .roundedSquare

  let noBg: Bool = false

  init(chat: Chat, size: CGFloat = 20, shape: IconShape = .roundedSquare) {
    emoji = Self.normalizedEmoji(chat.emoji)
    self.size = size
    self.shape = shape
  }

  init(emoji: String?, size: CGFloat = 20, shape: IconShape = .roundedSquare) {
    self.emoji = Self.normalizedEmoji(emoji)
    self.size = size
    self.shape = shape
  }

  var body: some View {
    background
      .frame(width: size, height: size)
      .overlay {
        if let emoji {
          Text(emoji)
            .font(.system(size: emojiPointSize))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        } else {
          Image(systemName: "bubble.middle.bottom.fill")
            .font(.system(size: symbolPointSize, weight: .semibold))
            .foregroundStyle(.secondary)
        }
      }
      .fixedSize()
  }

  @ViewBuilder
  private var background: some View {
    if noBg {
      Color.clear
    } else {
      switch shape {
        case .roundedSquare:
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.quinary)
        case .circle:
          Circle()
            .fill(.quinary)
      }
    }
  }

  private var cornerRadius: CGFloat {
    size * 0.4
  }

  private var emojiPointSize: CGFloat {
    size * (noBg ? 0.7 : 0.65)
  }

  private var symbolPointSize: CGFloat {
    size * (noBg ? 0.55 : 0.5)
  }

  private static func normalizedEmoji(_ emoji: String?) -> String? {
    guard let emoji else { return nil }
    let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

#Preview {
  HStack(spacing: 12) {
    SidebarThreadIcon(emoji: "💬")
    SidebarThreadIcon(emoji: nil)
    SidebarThreadIcon(emoji: "🧠", size: 24)
    SidebarThreadIcon(emoji: "💬", size: 32, shape: .circle)
    SidebarThreadIcon(emoji: nil, size: 32, shape: .circle)
  }
  .padding()
}
