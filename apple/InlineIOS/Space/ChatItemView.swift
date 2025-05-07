import InlineKit
import InlineUI
import SwiftUI

struct ChatItemProps {
  let dialog: Dialog
  let user: UserInfo?
  let chat: Chat?
  let message: Message?
  let from: UserInfo?
}

struct ChatItemView: View {
  let props: ChatItemProps

  init(props: ChatItemProps) {
    self.props = props
  }

  var dialog: Dialog {
    props.dialog
  }

  var user: UserInfo? {
    props.user
  }

  var chat: Chat? {
    props.chat
  }

  var message: Message? {
    props.message
  }

  var from: UserInfo? {
    props.from
  }

  var hasUnreadMessages: Bool {
    props.dialog.unreadCount ?? 0 > 0
  }

  var body: some View {
    VStack {
      HStack(alignment: .top, spacing: 9) {
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
          colors: [
            Color(.systemGray3).adjustLuminosity(by: 0.2),
            Color(.systemGray5).adjustLuminosity(by: 0),
          ],
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
      Circle()
        .fill(hasUnreadMessages ? ColorManager.shared.swiftUIColor : .clear)
        .frame(width: 6, height: 6)
        .animation(.easeInOut(duration: 0.3), value: hasUnreadMessages)
      chatProfile
    }
  }

  @ViewBuilder
  var title: some View {
    Text(chat?.title ?? "")
      .font(.customTitle())
      .foregroundColor(.primary)
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
        .font(.customCaption())
        .foregroundColor(.primary)
    }
    .padding(.top, 2)
  }

  @ViewBuilder
  var lastMessageView: some View {
    if message?.isSticker == true {
      HStack(spacing: 4) {
        Image(systemName: "cup.and.saucer.fill")
          .font(.customCaption())
          .foregroundColor(.secondary)

        Text("Sticker")
          .font(.customCaption())
          .foregroundColor(.secondary)
          .lineLimit(2)
          .truncationMode(.tail)
      }
      .padding(.top, 1)
    } else if message?.photoId != nil || message?.fileId != nil {
      HStack {
        Image(systemName: "photo.fill")
          .font(.customCaption())
          .foregroundColor(.secondary)

        Text("Photo")
          .font(.customCaption())
          .foregroundColor(.secondary)
      }
    } else if message?.hasUnsupportedTypes == true {
      Text("Unsupported message")
        .italic()
        .font(.customCaption())
        .foregroundColor(.secondary)

    } else {
      Text(message?.text ?? "")
        .font(.customCaption())
        .foregroundColor(.secondary)
    }
  }

  @ViewBuilder
  var titleAndLastMessageView: some View {
    VStack(alignment: .leading, spacing: 2) {
      title
      lastMessageSenderView
      lastMessageView
    }
  }
}
