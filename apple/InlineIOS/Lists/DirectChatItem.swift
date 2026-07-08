import InlineKit
import InlineUI
import SwiftUI
import Translation

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
    (dialog.unreadCount ?? 0) > 0 || (dialog.unreadMark == true)
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
    .frame(height: 50)
    .frame(maxWidth: .infinity, alignment: .top)
    .padding(.leading, -8)
  }

  @ViewBuilder
  var userProfile: some View {
    if let userInfo {
      UserAvatar(userInfo: userInfo, size: 60)
      .overlay(alignment: .bottomTrailing) {
        if isPinned {
          if #available(iOS 26.0, *) {
            Circle()
              .fill(.yellow.opacity(0.9))
              .frame(width: 22, height: 22)
              .glassEffect()
              .overlay {
                Image(systemName: "pin.fill")
                  .font(.caption)
                  .foregroundColor(.white)
              }

          } else {
            Circle()
              .fill(.yellow)
              .frame(width: 22, height: 22)
              .overlay {
                Image(systemName: "pin.fill")
                  .font(.caption)
                  .foregroundColor(.white)
              }
          }
        }
      }
    }
  }

  @ViewBuilder
  var unreadAndProfileView: some View {
    HStack(alignment: .center, spacing: 5) {
      Circle()
        .fill(hasUnreadMessages ? ColorManager.shared.swiftUIColor : .clear)
        .frame(width: 8, height: 8)
        .animation(.easeInOut(duration: 0.3), value: hasUnreadMessages)

      userProfile
    }
  }

  @ViewBuilder
  var title: some View {
    if let userInfo {
      Text(displayName(for: userInfo))
        .font(.body)
    } else {
      Text("Unknown User")
        .font(.body)
    }
  }

  private func displayName(for userInfo: UserInfo) -> String {
    return userInfo.user.needsDisplayNameFetch ? "Loading..." : userInfo.user.displayName
  }

  @ViewBuilder
  var lastMessage: some View {
    if showTypingIndicator {
      let action = currentComposeAction()
      HStack(alignment: .center, spacing: 4) {
        composeActionIndicator(action)

        Text(action?.toHumanReadableForIOS() ?? "")
          .font(.callout)
          .foregroundStyle(composeActionForegroundColor(action))
      }

    } else {
      Text(lastMsg?.displayTextForLastMessage ?? lastMsg?.message.stringRepresentationWithEmoji ?? "")
        .lineLimit(2)
        .truncationMode(.tail)
        .font(.callout)
        .foregroundStyle(.secondary)
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
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private func composeActionIndicator(_ action: ApiComposeAction?) -> some View {
    switch action {
    case .typing:
      TypingActivityIndicator(color: .accentColor)
    case .uploadingPhoto:
      UploadProgressIndicator(color: .secondary)
        .frame(width: 14)
    case .uploadingDocument:
      UploadProgressIndicator(color: .secondary)
        .frame(width: 14)
    case .uploadingVideo:
      UploadProgressIndicator(color: .secondary)
        .frame(width: 14)
    case .recordingVoice:
      VoiceRecordingActivityIndicator(
        barWidth: 2.2,
        spacing: 2.2,
        minBarHeight: 4,
        maxBarHeight: 11,
        color: .accentColor
      )
    case .none:
      EmptyView()
    }
  }

  private func composeActionForegroundColor(_ action: ApiComposeAction?) -> Color {
    switch action {
    case .typing, .recordingVoice:
      .accentColor
    default:
      .secondary
    }
  }
}
