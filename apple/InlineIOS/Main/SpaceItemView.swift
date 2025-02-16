import InlineKit
import InlineUI
import SwiftUI

struct SpaceItemProps {
  let space: Space
  let members: [Member]
  let chats: [SpaceChatItem]
}

struct SpaceItemView: View {
  let props: SpaceItemProps

  init(props: SpaceItemProps) {
    self.props = props
  }

  var space: Space {
    props.space
  }

  var members: [Member] {
    props.members
  }

  var hasUnreadMessages: Bool {
    props.chats.contains { $0.dialog.unreadCount ?? 0 > 0 }
  }

  var lastActiveChat: SpaceChatItem? {
    props.chats.sorted { item1, item2 in
      let date1 = item1.message?.date ?? .distantPast
      let date2 = item2.message?.date ?? .distantPast
      return date1 > date2
    }.first
  }

  var lastActiveChatMessageSender: UserInfo? {
    lastActiveChat?.from
  }

  var lastActiveChatMessage: Message? {
    lastActiveChat?.message
  }

  var lastMsgSenderName: String {
    lastActiveChatMessageSender?.user.firstName ?? ""
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
  var spaceProfile: some View {
    SpaceAvatar(space: space, size: 38)
  }

  @ViewBuilder
  var unreadAndProfileView: some View {
    HStack(alignment: .center, spacing: 5) {
      Circle()
        .fill(hasUnreadMessages ? Color.accentColor : .clear)
        .frame(width: 6, height: 6)
        .animation(.easeInOut(duration: 0.3), value: hasUnreadMessages)
      spaceProfile
    }
  }

  @ViewBuilder
  var title: some View {
    Text(space.name)
      .font(.customTitle())
      .foregroundColor(.primary)
  }

  @ViewBuilder
  var lastActiveChatView: some View {
    HStack(spacing: 4) {
      if let lastActiveChat = lastActiveChat {
        if let emoji = lastActiveChat.chat?.emoji {
          Text(String(describing: emoji).replacingOccurrences(of: "Optional(\"", with: "").replacingOccurrences(of: "\")", with: ""))
            .font(.customCaption())
        } else {
          Image(systemName: "bubble.right.fill")
            .foregroundColor(.primary)
            .font(.caption2)
        }

        Text(lastActiveChat.chat?.title ?? "")
          .font(.customCaption())
          .foregroundColor(.primary)
      }
    }
    .padding(.top, 2)
  }

  @ViewBuilder
  var lastActiveChatMessageView: some View {
    HStack(spacing: 4) {
      if let lastActiveChatMessageSender {
        UserAvatar(userInfo: lastActiveChatMessageSender, size: 15)
        Text("\(lastMsgSenderName):")
          .font(.customCaption())
          .foregroundColor(.secondary)
        Text(lastActiveChatMessage?.text ?? "")
          .font(.customCaption())
          .foregroundColor(.secondary)
      } else if let user = lastActiveChat?.from?.user {
        UserAvatar(user: user, size: 15)
        Text("\(lastMsgSenderName):")
          .font(.customCaption())
          .foregroundColor(.secondary)
        Text(lastActiveChatMessage?.text ?? "")
          .font(.customCaption())
          .foregroundColor(.secondary)
      }
    }
  }

  @ViewBuilder
  var titleAndLastMessageView: some View {
    VStack(alignment: .leading, spacing: 2) {
      title
      lastActiveChatView
      lastActiveChatMessageView
    }
  }
}
