import Auth
import InlineKit
import InlineUI
import RealtimeV2
import SwiftUI

struct ChatToolbarLeadingView: View {
  let peerId: Peer
  @Binding private var isChatHeaderPressed: Bool

  @EnvironmentObject private var fullChatViewModel: FullChatViewModel
  @EnvironmentObject private var realtimeState: RealtimeState
  @Environment(Router.self) private var router
  @Environment(\.colorScheme) private var colorScheme

  @ObservedObject private var composeActions: ComposeActions

  init(
    peerId: Peer,
    isChatHeaderPressed: Binding<Bool>,
    composeActions: ComposeActions = .shared
  ) {
    self.peerId = peerId
    _isChatHeaderPressed = isChatHeaderPressed
    _composeActions = ObservedObject(initialValue: composeActions)
  }

  private var toolbarAvatarSize: CGFloat {
    if #available(iOS 26.0, *) {
      44
    } else {
      32
    }
  }

  private var isCurrentUser: Bool {
    fullChatViewModel.peerUser?.id == Auth.shared.getCurrentUserId()
  }

  private var title: String {
    if case .user = peerId {
      isCurrentUser ? "Saved Message" : fullChatViewModel.peerUser?.firstName ?? fullChatViewModel.peerUser?
        .username ?? fullChatViewModel.peerUser?.email ?? fullChatViewModel.peerUser?.phoneNumber ?? "Invited User"
    } else {
      fullChatViewModel.chat?.humanReadableTitle ?? "Not Loaded Title"
    }
  }

  private var isPrivateChat: Bool {
    fullChatViewModel.peer.isPrivate
  }

  private var isThreadChat: Bool {
    fullChatViewModel.peer.isThread
  }

  private var chatProfileColors: [Color] {
    let _ = colorScheme
    return [
      Color(.systemGray3).adjustLuminosity(by: 0.2),
      Color(.systemGray5).adjustLuminosity(by: 0),
    ]
  }

  private func currentComposeAction() -> ApiComposeAction? {
    composeActions.getComposeAction(for: peerId)?.action
  }

  private func getCurrentSubtitle() -> ChatSubtitle {
    if let displayedConnectionState = realtimeState.displayedConnectionState {
      return .connectionState(displayedConnectionState)
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
  private var subtitleView: some View {
    let subtitle = getCurrentSubtitle()
    if !subtitle.text.isEmpty {
      HStack(alignment: .center, spacing: 4) {
        subtitle.animatedIndicator.padding(.top, 2)

        Text(subtitle.shouldKeepOriginalCase ? subtitle.text : subtitle.text.lowercased())
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .allowsTightening(true)
      }
      .padding(.top, -2)
    }
  }

  var body: some View {
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
            .frame(width: toolbarAvatarSize, height: toolbarAvatarSize)
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
          .lineLimit(1)
          .truncationMode(.tail)
          .allowsTightening(true)
        subtitleView
      }
    }
    // Important: do not use `fixedSize()` here. In a navigation bar toolbar item (principal/leading),
    // `fixedSize()` makes this view resist width constraints, so long titles can overlap the system
    // navigation buttons instead of truncating within the available space.
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
  let subtitle: ChatSubtitle

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
