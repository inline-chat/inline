import Auth
import InlineKit
import InlineUI
import RealtimeV2
import SwiftUI

struct ChatToolbarLeadingView: View {
  let peerId: Peer
  let contextSpaceId: Int64?
  @Binding private var isChatHeaderPressed: Bool

  @EnvironmentObject private var fullChatViewModel: FullChatViewModel
  @EnvironmentObject private var realtimeState: RealtimeState
  @Environment(Router.self) private var router
  @Environment(\.colorScheme) private var colorScheme

  @ObservedObject private var composeActions: ComposeActions
  @State private var toolbarContext: ReplyThreadToolbarContext?

  init(
    peerId: Peer,
    contextSpaceId: Int64? = nil,
    isChatHeaderPressed: Binding<Bool>,
    composeActions: ComposeActions = .shared
  ) {
    self.peerId = peerId
    self.contextSpaceId = contextSpaceId
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
    peerId.asUserId() == Auth.shared.getCurrentUserId()
  }

  private var title: String {
    if case .user = peerId {
      return isCurrentUser ? "Saved Message" : fullChatViewModel.peerUser.map {
        $0.needsDisplayNameFetch ? "Loading..." : $0.displayName
      } ?? "Loading..."
    } else if let chat = fullChatViewModel.chat {
      if chat.isReplyThread {
        return toolbarContext?.title ?? ReplyThreadToolbarContextLoader.fallbackTitle(for: chat)
      }
      return chat.humanReadableTitle ?? "Not Loaded Title"
    }

    return "Not Loaded Title"
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

  private var activeContextSpaceId: Int64? {
    if let contextSpaceId {
      return contextSpaceId
    }

    return router.selectedTabPath.reversed().dropFirst().compactMap { destination in
      if case let .space(id) = destination {
        return id
      }
      return nil
    }.first
  }

  private var toolbarContextKey: String {
    guard let chat = fullChatViewModel.chat else {
      return "none:\(activeContextSpaceId ?? 0)"
    }

    return [
      "\(chat.id)",
      "\(chat.spaceId ?? 0)",
      "\(chat.parentChatId ?? 0)",
      "\(chat.parentMessageId ?? 0)",
      chat.title ?? "",
      "\(activeContextSpaceId ?? 0)",
    ].joined(separator: ":")
  }

  private var threadEmoji: String {
    let emoji = fullChatViewModel.chat?.emoji?.trimmingCharacters(in: .whitespacesAndNewlines)
    return emoji?.isEmpty == false ? emoji! : "#"
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
      subtitleContent(subtitle)
    } else if let toolbarContext, toolbarContext.hasBreadcrumb {
      breadcrumbView(toolbarContext)
    }
  }

  private func subtitleContent(_ subtitle: ChatSubtitle) -> some View {
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

  private func breadcrumbView(_ context: ReplyThreadToolbarContext) -> some View {
    HStack(alignment: .center, spacing: 4) {
      if let space = context.space {
        breadcrumbButton(title: space.title, accessibilityLabel: "Open space \(space.title)") {
          openSpace(space)
        }

        if context.parent != nil {
          Text("/")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }

      if let parent = context.parent {
        breadcrumbButton(title: parent.title, accessibilityLabel: "Open parent chat \(parent.title)") {
          openParentThread(parent)
        }
        .layoutPriority(1)
      }
    }
    .lineLimit(1)
    .padding(.top, -2)
  }

  private func breadcrumbButton(
    title: String,
    accessibilityLabel: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .allowsTightening(true)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
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
            Text(threadEmoji)
              .font(.title2)
          }
          .onTapGesture(perform: openChatInfo)
      } else {
        if let user = fullChatViewModel.peerUserInfo {
          UserAvatar(userInfo: user, size: toolbarAvatarSize)
            .frame(width: toolbarAvatarSize, height: toolbarAvatarSize)
            .onTapGesture(perform: openChatInfo)
        } else {
          Circle()
            .fill(
              LinearGradient(
                colors: chatProfileColors,
                startPoint: .top,
                endPoint: .bottom
              )
            ).frame(width: toolbarAvatarSize, height: toolbarAvatarSize)
            .onTapGesture(perform: openChatInfo)
        }
      }

      VStack(alignment: .leading, spacing: 0) {
        Text(title)
          .font(.body)
          .fontWeight(.medium)
          .lineLimit(1)
          .truncationMode(.tail)
          .allowsTightening(true)
          .onTapGesture(perform: openChatInfo)
        subtitleView
      }
    }
    // Important: do not use `fixedSize()` here. In a navigation bar toolbar item (principal/leading),
    // `fixedSize()` makes this view resist width constraints, so long titles can overlap the system
    // navigation buttons instead of truncating within the available space.
    .opacity(isChatHeaderPressed ? 0.7 : 1.0)
    .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
      withAnimation(.easeInOut(duration: 0.1)) {
        isChatHeaderPressed = pressing
      }
    }, perform: {})
    .task(id: toolbarContextKey) {
      await loadToolbarContext()
    }
  }

  @MainActor
  private func loadToolbarContext() async {
    guard let chat = fullChatViewModel.chat,
          chat.isReplyThread || shouldShowSpaceBreadcrumb(for: chat)
    else {
      toolbarContext = nil
      return
    }

    let chatId = chat.id
    let spaceId = activeContextSpaceId
    let context = await ReplyThreadToolbarContextLoader.load(for: chat, contextSpaceId: spaceId)
    guard !Task.isCancelled, fullChatViewModel.chat?.id == chatId else { return }
    toolbarContext = context
  }

  private func shouldShowSpaceBreadcrumb(for chat: Chat) -> Bool {
    guard let spaceId = chat.spaceId else { return false }
    return spaceId != activeContextSpaceId
  }

  private func openParentThread(_ parent: ReplyThreadToolbarContext.ParentLink) {
    guard parent.peer != peerId else { return }
    router.push(.chat(peer: parent.peer))
  }

  private func openSpace(_ space: ReplyThreadToolbarContext.SpaceLink) {
    router.push(.space(id: space.id))
  }

  private func openChatInfo() {
    if let chatItem = fullChatViewModel.chatItem {
      router.presentSheet(.chatInfo(chatItem: chatItem))
    }
  }
}

enum ChatSubtitle {
  case connectionState(RealtimeConnectionState)
  case typing(String)
  case composeAction(ApiComposeAction)
  case timezone(String)
  case parentThread(String)
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
      case let .parentThread(title):
        title
      case .empty:
        ""
    }
  }

  var shouldKeepOriginalCase: Bool {
    switch self {
      case .typing:
        true
      case .parentThread:
        true
      default:
        false
    }
  }

  var isParentThread: Bool {
    if case .parentThread = self {
      return true
    }
    return false
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
      case .parentThread:
        Image(systemName: "arrowshape.turn.up.left")
          .font(.caption2)
          .foregroundStyle(.secondary)
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

        Text(subtitle.shouldKeepOriginalCase ? subtitle.text : subtitle.text.lowercased())
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
    ChatSubtitlePreview(subtitle: .parentThread("Parent Chat"))

    // Empty
    ChatSubtitlePreview(subtitle: .empty)
  }
  .padding()
  .background(Color(uiColor: .systemBackground))
}
