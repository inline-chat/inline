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
    case composeAction(ApiComposeAction)
    case timezone(String)
    case empty

    var text: String {
      switch self {
        case let .apiState(state):
          getStatusTextForChatHeader(state)
        case let .composeAction(action):
          action.toHumanReadableForIOS()
        case let .timezone(timezone):
          TimeZoneFormatter.shared.formatTimeZoneInfo(userTimeZoneId: timezone) ?? ""
        case .empty:
          ""
      }
    }

    var isComposeAction: Bool {
      switch self {
        case .composeAction:
          true
        default:
          false
      }
    }

    @ViewBuilder
    var animatedIndicator: some View {
      switch self {
        case let .composeAction(action):
          switch action {
            case .typing:
              AnimatedDots(dotSize: 3, dotColor: Color(ThemeManager.shared.selected.accent))
            case .uploadingPhoto:
              AnimatedPhotoUpload()
            case .uploadingDocument:
              AnimatedDocumentUpload()
            case .uploadingVideo:
              AnimatedVideoUpload()
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
        return .composeAction(composeAction)
      } else if let user = fullChatViewModel.peerUserInfo?.user,
                let timeZone = user.timeZone,
                timeZone != TimeZone.current.identifier
      {
        return .timezone(timeZone)
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

        Text(subtitle.text.lowercased())
          .font(.caption)
          .foregroundStyle(subtitle.isComposeAction ? Color(ThemeManager.shared.selected.accent) : .secondary)
      }
      .padding(.top, -2)
      .fixedSize()
    }
  }
}

// MARK: - Animated Indicators

private struct AnimatedPhotoUpload: View {
  var body: some View {
    UploadProgressIndicator(color: Color(ThemeManager.shared.selected.accent))
      .frame(width: 14)
  }
}

private struct AnimatedDocumentUpload: View {
  var body: some View {
    UploadProgressIndicator(color: Color(ThemeManager.shared.selected.accent))
      .frame(width: 14)
  }
}

private struct AnimatedVideoUpload: View {
  var body: some View {
    UploadProgressIndicator(color: Color(ThemeManager.shared.selected.accent))
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
          .foregroundStyle(subtitle.isComposeAction ? Color(ThemeManager.shared.selected.accent) : .secondary)
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

    // Compose Actions
    ChatSubtitlePreview(subtitle: .composeAction(.typing))
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
