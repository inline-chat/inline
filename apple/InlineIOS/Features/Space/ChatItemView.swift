import InlineKit
import InlineUI
import SwiftUI

struct ChatItemProps {
  let dialog: Dialog
  let user: UserInfo?
  let chat: Chat?
  let message: EmbeddedMessage?
  let space: Space?

  // Backward compatibility
  init(dialog: Dialog, user: UserInfo?, chat: Chat?, message: EmbeddedMessage?, space: Space?) {
    self.dialog = dialog
    self.user = user
    self.chat = chat
    self.message = message
    self.space = space
  }

  // Backward compatibility initializer for old Message/UserInfo structure
  init(dialog: Dialog, user: UserInfo?, chat: Chat?, message: Message?, from: UserInfo?, space: Space?) {
    self.dialog = dialog
    self.user = user
    self.chat = chat
    self.space = space

    // Convert old structure to EmbeddedMessage
    if let message {
      self.message = EmbeddedMessage(message: message, senderInfo: from, translations: [])
    } else {
      self.message = nil
    }
  }
}

struct ChatItemView: View {
  let props: ChatItemProps

  init(props: ChatItemProps) {
    self.props = props
  }

  @Environment(\.colorScheme) private var colorScheme

  var dialog: Dialog {
    props.dialog
  }

  var user: UserInfo? {
    props.user
  }

  var chat: Chat? {
    props.chat
  }

  var message: EmbeddedMessage? {
    props.message
  }

  var from: UserInfo? {
    props.message?.senderInfo
  }

  var space: Space? {
    props.space
  }

  var hasUnreadMessages: Bool {
    props.dialog.unreadCount ?? 0 > 0
  }

  var isPinned: Bool {
    props.dialog.pinned ?? false
  }

  private var chatProfileColors: [Color] {
    let _ = colorScheme
    return [
      Color(.systemGray3).adjustLuminosity(by: 0.2),
      Color(.systemGray5).adjustLuminosity(by: 0),
    ]
  }

  var body: some View {
    VStack {
      HStack(alignment: .top, spacing: 14) {
        unreadAndProfileView
        titleAndLastMessageView
        Spacer()
      }
      Spacer()
    }
    .frame(height: 70)
    .frame(maxWidth: .infinity, alignment: .top)
    .padding(.leading, -8)
  }

  @ViewBuilder
  var chatProfile: some View {
    Circle()
      .fill(
        LinearGradient(
          colors: chatProfileColors,
          startPoint: .top,
          endPoint: .bottom
        )
      )
      .frame(width: 58, height: 58)
      .overlay {
        Group {
          if let emoji = chat?.emoji {
            Text(
              String(describing: emoji).replacingOccurrences(of: "Optional(\"", with: "")
                .replacingOccurrences(of: "\")", with: "")
            )
            .font(.largeTitle)
          } else {
            Text("💬")
              .font(.largeTitle)
          }
        }
      }
  }

  @ViewBuilder
  var unreadAndProfileView: some View {
    HStack(alignment: .center, spacing: 5) {
      if isPinned, !hasUnreadMessages {
        Image(systemName: "pin.fill")
          .resizable()
          .foregroundColor(.secondary)
          .frame(width: 8, height: 10)

      } else {
        Circle()
          .fill(hasUnreadMessages ? ColorManager.shared.swiftUIColor : .clear)
          .frame(width: 8, height: 8)
          .animation(.easeInOut(duration: 0.3), value: hasUnreadMessages)
      }
      chatProfile
    }
  }

  @ViewBuilder
  var title: some View {
    HStack(alignment: .center) {
      Text(chat?.title ?? "")
        .font(.body)
        .foregroundColor(.primary)
      Spacer()

      if let space {
        Text(space.name)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
  }

  @ViewBuilder
  var lastMessageSenderView: some View {
    HStack(spacing: 4) {
      if let from {
        UserAvatar(userInfo: from, size: 15)
      } else if let user = from?.user {
        UserAvatar(user: user, size: 15)
      }

      Text(from?.user.firstName ?? "")
        .font(.callout)
        .foregroundColor(.secondary)
    }
    .padding(.top, 2)
  }

  @ViewBuilder
  var lastMessageView: some View {
    if message?.message.isSticker == true {
      HStack(spacing: 4) {
        Image(systemName: "cup.and.saucer.fill")
          .font(.callout)
          .foregroundColor(.secondary)

        Text("Sticker")
          .font(.callout)
          .foregroundColor(.secondary)
          .lineLimit(2)
          .truncationMode(.tail)
      }
      .padding(.top, 1)
    } else if message?.message.documentId != nil {
      HStack {
        Image(systemName: "document.fill")
          .font(.callout)
          .foregroundColor(.secondary)

        Text(
          (message?.message.hasText == true ? message?.displayText ?? "" : "Document")
            .replacingOccurrences(of: "\n", with: " ")
        )
        .font(.callout)
        .foregroundColor(.secondary)
        .lineLimit(2)
        .truncationMode(.tail)
      }
      .padding(.top, 1)
    } else if message?.message.photoId != nil || message?.message.fileId != nil {
      HStack {
        Image(systemName: "photo.fill")
          .font(.callout)

        Text(
          (message?.message.hasText == true ? message?.displayText ?? "" : "Photo")
            .replacingOccurrences(of: "\n", with: " ")
        )
        .font(.callout)
        .foregroundColor(.secondary)
        .lineLimit(2)
        .truncationMode(.tail)
      }
      .padding(.top, 1)
    } else if message?.message.hasUnsupportedTypes == true {
      Text("Unsupported message")
        .italic()
        .font(.callout)
        .foregroundColor(.secondary)

    } else {
      Text((message?.displayText ?? "").replacingOccurrences(of: "\n", with: " "))
        .font(.callout)
        .foregroundColor(.secondary)
    }
  }

  @ViewBuilder
  var titleAndLastMessageView: some View {
    VStack(alignment: .leading, spacing: 0) {
      title
      lastMessageSenderView
      lastMessageView
    }
  }
}
