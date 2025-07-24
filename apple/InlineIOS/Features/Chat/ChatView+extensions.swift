import Auth
import InlineKit
import RealtimeAPI
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
    case apiState(RealtimeAPIState)
    case typing(String)
    case composeAction(ApiComposeAction)
    case timezone(String)
    case empty

    var text: String {
      switch self {
        case let .apiState(state):
          getStatusTextForChatHeader(state)
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
    if apiState != .connected {
      return .apiState(apiState)
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
    HStack(alignment: .center, spacing: 4) {
      subtitle.animatedIndicator.padding(.top, 2)

      Text(subtitle.text.isEmpty ? " " : subtitle.text.lowercased())
        .font(.caption)
        .foregroundStyle(.secondary)
        .opacity(subtitle.text.isEmpty ? 0 : 1)
    }
    .padding(.top, -2)
    .frame(maxWidth: .infinity, alignment: .leading)
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
    // API States
    ChatSubtitlePreview(subtitle: .apiState(.connecting))
    ChatSubtitlePreview(subtitle: .apiState(.updating))
    ChatSubtitlePreview(subtitle: .apiState(.waitingForNetwork))

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
