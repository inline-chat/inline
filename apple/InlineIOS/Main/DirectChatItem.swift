import Auth
import InlineKit
import InlineUI
import SwiftUI

struct Props {
  let dialog: Dialog
  let user: UserInfo?
  let chat: Chat?
  let message: EmbeddedMessage?

  // Primary initializer
  init(dialog: Dialog, user: UserInfo?, chat: Chat?, message: EmbeddedMessage?) {
    self.dialog = dialog
    self.user = user
    self.chat = chat
    self.message = message
  }

  // Backward compatibility initializer for old Message/User structure
  init(dialog: Dialog, user: UserInfo?, chat: Chat?, message: Message?, from: User?) {
    self.dialog = dialog
    self.user = user
    self.chat = chat

    // Convert old structure to EmbeddedMessage
    if let message {
      let userInfo = from.map { UserInfo(user: $0) }
      self.message = EmbeddedMessage(message: message, senderInfo: userInfo, translations: [])
    } else {
      self.message = nil
    }
  }
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

  var lastMsg: EmbeddedMessage? {
    props.message
  }

  var from: User? {
    props.message?.from
  }

  var hasUnreadMessages: Bool {
    (dialog.unreadCount ?? 0) > 0
  }

  var isPinned: Bool {
    dialog.pinned ?? false
  }

  @ObservedObject var composeActions: ComposeActions = .shared
  @Environment(\.colorScheme) private var colorScheme

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
      if userInfo.user.id == Auth.shared.getCurrentUserId() {
        InitialsCircle(
          name: UserAvatar.getNameForInitials(user: userInfo.user),
          size: 58,
          symbol: "bookmark.fill"
        )
      } else {
        UserAvatar(userInfo: userInfo, size: 58)
      }
    }
  }

  @ViewBuilder
  var unreadAndProfileView: some View {
    HStack(alignment: .center, spacing: 5) {
      if isPinned && !hasUnreadMessages {
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
      userProfile
    }
  }

  @ViewBuilder
  var title: some View {
    if let userInfo {
      Text(displayName(for: userInfo))
        .font(.body)
        .foregroundColor(.primary)
    } else {
      Text("Unknown User")
        .font(.body)
        .foregroundColor(.primary)
    }
  }

  private func displayName(for userInfo: UserInfo) -> String {
    if userInfo.user.id == Auth.shared.getCurrentUserId() {
      return "Saved Message"
    }

    return userInfo.user.firstName
      ?? userInfo.user.username
      ?? userInfo.user.email
      ?? userInfo.user.phoneNumber
      ?? "Invited User"
  }

  @ViewBuilder
  var lastMessage: some View {
    if showTypingIndicator {
      HStack(alignment: .center, spacing: 4) {
        switch currentComposeAction() {
          case .typing:
            AnimatedDots(dotSize: 3, dotColor: .secondary)
          case .uploadingPhoto:
            UploadProgressIndicator(color: .secondary)
              .frame(width: 14)
          case .uploadingDocument:
            UploadProgressIndicator(color: .secondary)
              .frame(width: 14)
          case .uploadingVideo:
            UploadProgressIndicator(color: .secondary)
              .frame(width: 14)
          case .none:
            EmptyView()
        }

        Text(currentComposeAction()?.toHumanReadableForIOS() ?? "")
          .font(.customCaption())
          .foregroundStyle(.secondary)
      }
      .padding(.top, 1)
    } else if lastMsg?.message.isSticker == true {
      HStack(spacing: 4) {
        Image(systemName: "cup.and.saucer.fill")
          .font(.customCaption())
          .foregroundColor(.secondary)
        Text("Sticker")
          .font(.customCaption())
          .foregroundColor(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .padding(.top, 1)
    } else if lastMsg?.message.documentId != nil {
      HStack {
        Image(systemName: "document.fill")
          .font(.customCaption())
          .foregroundColor(.secondary)

        Text(
          (lastMsg?.message.hasText == true ? lastMsg?.displayText ?? "" : "Document")
            .replacingOccurrences(of: "\n", with: " ")
        )
        .font(.customCaption())
        .foregroundColor(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
      }
      .padding(.top, 1)
    } else if lastMsg?.message.photoId != nil || lastMsg?.message.fileId != nil {
      HStack {
        Image(systemName: "photo.fill")
          .font(.customCaption())
          .foregroundColor(.secondary)

        Text(
          (lastMsg?.message.hasText == true ? lastMsg?.displayText ?? "" : "Photo")
            .replacingOccurrences(of: "\n", with: " ")
        )
        .font(.customCaption())
        .foregroundColor(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
      }
      .padding(.top, 1)
    } else if lastMsg?.message.hasUnsupportedTypes == true {
      Text("Unsupported message")
        .italic()
        .font(.customCaption())
        .foregroundColor(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.top, 1)
    } else {
      Text((lastMsg?.displayText ?? "").replacingOccurrences(of: "\n", with: " "))
        .font(.customCaption())
        .foregroundColor(.secondary)
        .lineLimit(2)
        .truncationMode(.tail)
        .padding(.top, 1)
    }
  }

  @ViewBuilder
  var messageDate: some View {
    Text(lastMsg?.message.date.formatted() ?? "")
      .font(.smallLabel())
      .foregroundColor(Color(.tertiaryLabel))
  }

  @ViewBuilder
  var titleAndLastMessageView: some View {
    VStack(alignment: .leading, spacing: 0) {
//      HStack(spacing: 0) {
      title
//        Spacer()
//        messageDate
//      }
      lastMessage
    }
  }
}
