import InlineKit
import InlineUI
import SwiftUI

struct Props {
  let dialog: Dialog
  let user: UserInfo?
  let chat: Chat?
  let message: Message?
  let from: User?
}

struct DirectChatItem: View {
  let props: Props

  init(props: Props) {
    self.props = props
  }

  var dialog: Dialog {
    props.dialog
  }

  var userInfo: UserInfo? {
    props.user
  }

  var chat: Chat? {
    props.chat
  }

  var lastMsg: Message? {
    props.message
  }

  var from: User? {
    props.from
  }

  var hasUnreadMessages: Bool {
    (dialog.unreadCount ?? 0) > 0
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
  var userProfile: some View {
    if let userInfo = userInfo {
      UserAvatar(userInfo: userInfo, size: 38)
    }
  }

  @ViewBuilder
  var unreadAndProfileView: some View {
    HStack(alignment: .center, spacing: 5) {
      Circle()
        .fill(hasUnreadMessages ? Color.accentColor : .clear)
        .frame(width: 6, height: 6)
        .animation(.easeInOut(duration: 0.3), value: hasUnreadMessages)
      userProfile
    }
  }

  @ViewBuilder
  var title: some View {
    Text(userInfo?.user.firstName ?? "")
      .font(.customTitle())
      .foregroundColor(.primary)
  }

  @ViewBuilder
  var lastMessage: some View {
    Text(lastMsg?.text ?? "")
      .font(.customCaption())
      .foregroundColor(.secondary)
      .lineLimit(2)
      .truncationMode(.tail)
      .padding(.top, 1)
  }

  @ViewBuilder
  var messageDate: some View {
    Text(lastMsg?.date.formatted() ?? "")
      .font(.smallLabel())
      .foregroundColor(Color(.tertiaryLabel))
  }

  @ViewBuilder
  var titleAndLastMessageView: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 0) {
        title
        Spacer()
        messageDate
      }
      lastMessage
    }
  }
}
