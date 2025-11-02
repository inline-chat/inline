import Auth
import InlineKit
import InlineUI
import RealtimeV2
import SwiftUI

extension ChatView {
  var isCurrentUser: Bool {
    fullChatViewModel.peerUser?.id == Auth.shared.getCurrentUserId()
  }

  var title: String {
    if case .user = peerId {
      isCurrentUser ? "Saved Message" : fullChatViewModel.peerUser?.firstName ?? fullChatViewModel.peerUser?
        .username ?? fullChatViewModel.peerUser?.email ?? fullChatViewModel.peerUser?.phoneNumber ?? "Invited User"
    } else {
      fullChatViewModel.chat?.title ?? "Not Loaded Title"
    }
  }

  func currentComposeAction() -> ApiComposeAction? {
    composeActions.getComposeAction(for: peerId)?.action
  }

  enum ChatSubtitle {
    case connectionState(RealtimeConnectionState)
    case typing(String)
    case composeAction(ApiComposeAction)
    case timezone(String)
    case empty

    var text: String {
      switch self {
        case let .connectionState(state):
          state.title.lowercased()
        case let .typing(text):
          text
        case let .composeAction(action):
          action.toHumanReadableForIOS()
        case let .timezone(timezone):
          TimeZoneFormatter.shared.formatTimeZoneInfo(userTimeZoneId: timezone) ?? ""
        case .empty:
          ""
      }
    }

    var shouldKeepOriginalCase: Bool {
      switch self {
        case .typing:
          true
        default:
          false
      }
    }

    @ViewBuilder
    var animatedIndicator: some View {
      switch self {
        case .typing:
          AnimatedDots(dotSize: 3, dotColor: .secondary)
        case let .composeAction(action):
          switch action {
            case .uploadingPhoto:
              AnimatedPhotoUpload()
            case .uploadingDocument:
              AnimatedDocumentUpload()
            case .uploadingVideo:
              AnimatedVideoUpload()
            default:
              EmptyView()
          }
        default:
          EmptyView()
      }
    }
  }

  func getCurrentSubtitle() -> ChatSubtitle {
    if realtimeState.connectionState != .connected {
      return .connectionState(realtimeState.connectionState)
    } else if isPrivateChat {
      if let composeAction = currentComposeAction() {
        if composeAction == .typing {
          if let typingText = composeActions.getTypingDisplayText(for: peerId, length: .min), !typingText.isEmpty {
            return .typing(typingText)
          } else {
            return .empty
          }
        } else {
          return .composeAction(composeAction)
        }
      } else if let user = fullChatViewModel.peerUserInfo?.user,
                let timeZone = user.timeZone,
                timeZone != TimeZone.current.identifier
      {
        return .timezone(timeZone)
      }
    } else {
      if let composeAction = currentComposeAction() {
        if composeAction == .typing {
          if let typingText = composeActions.getTypingDisplayText(for: peerId, length: .min), !typingText.isEmpty {
            return .typing(typingText)
          } else {
            return .empty
          }
        } else {
          return .composeAction(composeAction)
        }
      }
    }
    return .empty
  }

  @ViewBuilder
  var subtitleView: some View {
    let subtitle = getCurrentSubtitle()
    if !subtitle.text.isEmpty {
      HStack(alignment: .center, spacing: 4) {
        subtitle.animatedIndicator.padding(.top, 2)

        // Text(subtitle.text.lowercased())
        Text(subtitle.shouldKeepOriginalCase ? subtitle.text : subtitle.text.lowercased())
          .font(.caption)
//          .foregroundStyle(subtitle.isComposeAction ? Color(ThemeManager.shared.selected.accent) : .secondary)
          .foregroundStyle(.secondary)
      }
      .padding(.top, -2)
      .fixedSize()
    }
  }

  @ViewBuilder
  var toolbarLeadingView: some View {
    HStack(spacing: 8) {
      if isThreadChat {
        Circle()
          .fill(
            LinearGradient(
              colors: chatProfileColors,
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .frame(width: toolbarAvatarSize, height: toolbarAvatarSize)
          .overlay {
            Text(
              String(describing: fullChatViewModel.chat?.emoji ?? "💬")
                .replacingOccurrences(of: "Optional(\"", with: "")
                .replacingOccurrences(of: "\")", with: "")
            )
            .font(.title2)
          }
      } else {
        if let user = fullChatViewModel.peerUserInfo {
          UserAvatar(userInfo: user, size: toolbarAvatarSize)
        } else {
          Circle()
            .fill(
              LinearGradient(
                colors: chatProfileColors,
                startPoint: .top,
                endPoint: .bottom
              )
            ).frame(width: toolbarAvatarSize, height: toolbarAvatarSize)
        }
      }

      VStack(alignment: .leading, spacing: 0) {
        Text(title)
          .font(.body)
          .fontWeight(.medium)
        subtitleView
      }
    }
    .scaledToFill()
    .fixedSize()
    .opacity(isChatHeaderPressed ? 0.7 : 1.0)
    .onTapGesture {
      if let chatItem = fullChatViewModel.chatItem {
        router.push(.chatInfo(chatItem: chatItem))
      }
    }
    .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
      withAnimation(.easeInOut(duration: 0.1)) {
        isChatHeaderPressed = pressing
      }
    }, perform: {})
  }
}

// MARK: - Animated Indicators

private struct AnimatedPhotoUpload: View {
  var body: some View {
    UploadProgressIndicator(color: .secondary)
      .frame(width: 14)
  }
}

private struct AnimatedDocumentUpload: View {
  var body: some View {
    UploadProgressIndicator(color: .secondary)
      .frame(width: 14)
  }
}

private struct AnimatedVideoUpload: View {
  var body: some View {
    UploadProgressIndicator(color: .secondary)
      .frame(width: 14)
  }
}

// MARK: - Preview Provider

struct ChatSubtitlePreview: View {
  let subtitle: ChatView.ChatSubtitle

  var body: some View {
    VStack(spacing: 0) {
      Text("Chat").fontWeight(.medium)
      HStack(alignment: .center, spacing: 4) {
        subtitle.animatedIndicator.padding(.top, 2)

        Text(subtitle.text.lowercased())
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.top, -2)
      .fixedSize()
    }
  }
}

#Preview {
  VStack(spacing: 20) {
    // Connection States
    ChatSubtitlePreview(subtitle: .connectionState(.connecting))
    ChatSubtitlePreview(subtitle: .connectionState(.updating))
    ChatSubtitlePreview(subtitle: .connectionState(.connected))

    // Typing
    ChatSubtitlePreview(subtitle: .typing("John is typing..."))
    ChatSubtitlePreview(subtitle: .typing("John and Jane are typing..."))

    // Compose Actions
    ChatSubtitlePreview(subtitle: .composeAction(.uploadingPhoto))
    ChatSubtitlePreview(subtitle: .composeAction(.uploadingDocument))
    ChatSubtitlePreview(subtitle: .composeAction(.uploadingVideo))

    // Timezone
    ChatSubtitlePreview(subtitle: .timezone("America/New_York"))

    // Empty
    ChatSubtitlePreview(subtitle: .empty)
  }
  .padding()
  .background(Color(uiColor: .systemBackground))
}
