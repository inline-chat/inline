import InlineKit
import InlineUI
import SwiftUI

enum ExperimentalChatSymbol: String, CaseIterable, Identifiable {
  case circle
  case circleFill = "circle.fill"
  case document
  case textPage = "text.page"
  case message
  case stackForwardFill = "square.stack.3d.down.forward.fill"
  case stackRight = "square.stack.3d.down.right"
  case existing

  static let defaultsKey = "experimental.macChatSymbol"

  var id: String { rawValue }
  var title: String { self == .existing ? "Existing" : rawValue }
  // Existing keeps the experiment off by leaving the original fallback symbol unchanged.
  var symbolName: String? { self == .existing ? nil : rawValue }
}

struct SidebarThreadIcon: View, Equatable {
  @AppStorage(ExperimentalChatSymbol.defaultsKey) private var chatSymbol: ExperimentalChatSymbol = .existing

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.emoji == rhs.emoji && lhs.isReplyThread == rhs.isReplyThread &&
      lhs.size == rhs.size && lhs.shape == rhs.shape
  }

  enum IconShape: Equatable {
    case none
    case roundedSquare
    case circle

    var threadIconShape: ThreadIconShape {
      switch self {
      case .none:
        .none
      case .roundedSquare:
        .roundedSquare
      case .circle:
        .circle
      }
    }
  }

  let emoji: String?
  let isReplyThread: Bool
  var size: CGFloat = 20
  var shape: IconShape = .circle

  init(chat: Chat, size: CGFloat = 20, shape: IconShape = .circle) {
    emoji = chat.emoji
    isReplyThread = chat.isReplyThread
    self.size = size
    self.shape = shape
  }

  init(emoji: String?, isReplyThread: Bool = false, size: CGFloat = 20, shape: IconShape = .circle) {
    self.emoji = emoji
    self.isReplyThread = isReplyThread
    self.size = size
    self.shape = shape
  }

  var body: some View {
    ThreadIconView(
      ThreadIconDescriptor(
        emoji: emoji,
        isReplyThread: isReplyThread
      ),
      size: threadIconSize,
      shape: shape.threadIconShape,
      fallbackSymbolName: isReplyThread ? nil : chatSymbol.symbolName
    )
  }

  private var threadIconSize: ThreadIconSize {
    if shape == .none || size <= 24 {
      return .compact(size)
    }
    if size >= 50 {
      return .large(size)
    }
    return .regular(size)
  }
}

struct SidebarChatIdentityIcon: View, Equatable {
  let identity: ChatListIdentityDescriptor?
  let size: CGFloat
  let shape: SidebarThreadIcon.IconShape

  var body: some View {
    switch identity {
    case let .thread(descriptor):
      SidebarThreadIcon(
        emoji: descriptor.emoji,
        isReplyThread: descriptor.isReplyThread,
        size: size,
        shape: shape
      )
    case let .user(descriptor):
      UserAvatar(
        userID: descriptor.userID,
        firstName: descriptor.firstName,
        lastName: descriptor.lastName,
        email: descriptor.email,
        username: descriptor.username,
        stableAvatarIdentity: descriptor.stableAvatarIdentity,
        remoteURL: descriptor.remoteURL,
        localURL: descriptor.localURL,
        size: size
      )
      .equatable()
    case nil:
      Circle()
        .fill(Color.primary.opacity(0.08))
        .overlay {
          Image(systemName: "bubble.left")
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(.secondary)
        }
    }
  }
}

#Preview {
  HStack(spacing: 12) {
    SidebarThreadIcon(emoji: "💬", shape: .none)
    SidebarThreadIcon(emoji: nil, shape: .none)
    SidebarThreadIcon(emoji: "🧠", size: 24)
    SidebarThreadIcon(emoji: "💬", size: 32, shape: .circle)
    SidebarThreadIcon(emoji: nil, size: 32, shape: .roundedSquare)
  }
  .padding()
}
