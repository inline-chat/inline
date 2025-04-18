import Auth
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

  @ObservedObject var composeActions: ComposeActions = .shared

  private func currentComposeAction() -> ApiComposeAction? {
    composeActions.getComposeAction(for: Peer(userId: userInfo?.user.id ?? 0))?.action
  }

  private var showTypingIndicator: Bool {
    currentComposeAction()?.rawValue.isEmpty == false
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
  var userProfile: some View {
    if let userInfo {
      UserAvatar(userInfo: userInfo, size: 58)
    }
  }

  @ViewBuilder
  var unreadAndProfileView: some View {
    HStack(alignment: .center, spacing: 5) {
      Circle()
        .fill(hasUnreadMessages ? ColorManager.shared.swiftUIColor : .clear)
        .frame(width: 6, height: 6)
        .animation(.easeInOut(duration: 0.3), value: hasUnreadMessages)
      userProfile
    }
  }

  @ViewBuilder
  var title: some View {
    HStack(spacing: 4) {
      Text(userInfo?.user.firstName ?? "")
        .font(.customTitle())
        .foregroundColor(.primary)
      if userInfo?.user.id == Auth.shared.getCurrentUserId() {
        Text("(you)")
          .font(.customCaption())
          .foregroundColor(.secondary)
          .fontWeight(.medium)
      }
    }
  }

  @ViewBuilder
  var lastMessage: some View {
    if showTypingIndicator {
      HStack {
        AnimatedDots(dotSize: 4)
        Text("\(currentComposeAction()?.rawValue ?? "")")
          .font(.customCaption())
          .foregroundColor(.secondary)
          .lineLimit(2)
          .truncationMode(.tail)
      }
      .padding(.top, 1)

  } else if lastMsg?.isSticker == true {
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
  } else  if lastMsg?.photoId != nil || lastMsg?.fileId != nil {
      HStack {
        Image(systemName: "photo.fill")
          .font(.customCaption())
          .foregroundColor(.secondary)

        Text("Photo")
          .font(.customCaption())
          .foregroundColor(.secondary)
          .lineLimit(2)
          .truncationMode(.tail)
      }
      .padding(.top, 1)
    } else if lastMsg?.hasUnsupportedTypes == true {
      Text("Unsupported message")
        .italic()
        .font(.customCaption())
        .foregroundColor(.secondary)
        .lineLimit(2)
        .truncationMode(.tail)
        .padding(.top, 1)
    } else {
      Text(lastMsg?.text ?? "")
        .font(.customCaption())
        .foregroundColor(.secondary)
        .lineLimit(2)
        .truncationMode(.tail)
        .padding(.top, 1)
    }
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
