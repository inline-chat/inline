import InlineKit
import InlineUI
import RealtimeV2
import SwiftUI

struct ChatToolbarLeadingView: View {
  let peerId: Peer
  let contextSpaceId: Int64?
  private let router: Router
  let onOpenSpace: (Int64) -> Void
  let onOpenChatInfo: (SpaceChatItem) -> Void

  @ObservedObject private var fullChatViewModel: FullChatViewModel
  private let realtimeState: RealtimeState

  @State private var toolbarContext: ReplyThreadToolbarContext?

  init(
    peerId: Peer,
    contextSpaceId: Int64? = nil,
    router: Router,
    fullChatViewModel: FullChatViewModel,
    realtimeState: RealtimeState,
    onOpenSpace: @escaping (Int64) -> Void,
    onOpenChatInfo: @escaping (SpaceChatItem) -> Void
  ) {
    self.peerId = peerId
    self.contextSpaceId = contextSpaceId
    self.router = router
    self.realtimeState = realtimeState
    self.onOpenSpace = onOpenSpace
    self.onOpenChatInfo = onOpenChatInfo
    _fullChatViewModel = ObservedObject(wrappedValue: fullChatViewModel)
  }

  private var toolbarAvatarSize: CGFloat {
    if #available(iOS 26.0, *) {
      44
    } else {
      32
    }
  }

  private var title: String {
    if case .user = peerId {
      return fullChatViewModel.peerUser.map {
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

  private var subtitleFallback: ChatSubtitle {
    if isPrivateChat,
       let user = fullChatViewModel.peerUserInfo?.user,
       let timeZone = user.timeZone,
       timeZone != TimeZone.current.identifier,
       let text = TimeZoneFormatter.shared.formatTimeZoneInfo(userTimeZoneId: timeZone),
       !text.isEmpty {
      return .timezone(text)
    }

    if let toolbarContext, toolbarContext.hasBreadcrumb {
      return .breadcrumb(toolbarContext)
    }

    return .empty
  }

  @ViewBuilder
  private var avatar: some View {
    if isThreadChat {
      ThreadIconView(
        fullChatViewModel.chat.map(ThreadIconDescriptor.init(chat:)) ?? ThreadIconDescriptor(emoji: nil),
        size: .large(toolbarAvatarSize),
        shape: .circle,
        symbolColor: .mutedPrimary,
        contentScaleMultiplier: 0.88
      )
    } else if let user = fullChatViewModel.peerUserInfo {
      UserAvatar(userInfo: user, size: toolbarAvatarSize)
        .frame(width: toolbarAvatarSize, height: toolbarAvatarSize)
    } else {
      Circle()
        .fill(.quinary)
        .frame(width: toolbarAvatarSize, height: toolbarAvatarSize)
    }
  }

  var body: some View {
    HStack(spacing: 8) {
      Button(action: openChatInfo) {
        avatar
      }
      .buttonStyle(ChatToolbarHeaderButtonStyle())
      .accessibilityLabel("Open chat info")

      ChatToolbarTitleStack(
        title: title,
        minimumHeight: toolbarAvatarSize,
        peerId: peerId,
        fallback: subtitleFallback,
        realtimeState: realtimeState,
        onOpenChatInfo: openChatInfo,
        onOpenSpace: openSpace,
        onOpenParentThread: openParentThread
      )
      .id(peerId)
      .layoutPriority(1)

      Color.clear
        .frame(minWidth: 0, maxWidth: .infinity)
        .accessibilityHidden(true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    // Important: do not use `fixedSize()` here. In a navigation bar toolbar item (principal/leading),
    // `fixedSize()` makes this view resist width constraints, so long titles can overlap the system
    // navigation buttons instead of truncating within the available space.
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
    onOpenSpace(space.id)
  }

  private func openChatInfo() {
    if let chatItem = fullChatViewModel.chatItem {
      onOpenChatInfo(chatItem)
    }
  }
}

private struct ChatToolbarHeaderButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.72 : 1)
      .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.98 : 1))
      .animation(reduceMotion ? nil : .smooth(duration: 0.12), value: configuration.isPressed)
  }
}

enum ChatSubtitle: Equatable {
  case connectionState(String)
  case composeAction(ComposeActionPresentation)
  case timezone(String)
  case breadcrumb(ReplyThreadToolbarContext)
  case empty

  var transitionID: String {
    switch self {
    case let .connectionState(text):
      "connection:\(text)"
    case let .composeAction(presentation):
      "compose:\(presentation.action.rawValue):\(presentation.text)"
    case let .timezone(text):
      "timezone:\(text)"
    case let .breadcrumb(context):
      [
        "breadcrumb",
        "\(context.space?.id ?? 0)",
        context.space?.title ?? "",
        context.parent?.peer.toString() ?? "none",
        context.parent?.title ?? "",
      ].joined(separator: ":")
    case .empty:
      "empty"
    }
  }
}

private struct ChatToolbarTitleStack: View {
  let title: String
  let minimumHeight: CGFloat
  let peerId: Peer
  let fallback: ChatSubtitle
  let onOpenChatInfo: () -> Void
  let onOpenSpace: (ReplyThreadToolbarContext.SpaceLink) -> Void
  let onOpenParentThread: (ReplyThreadToolbarContext.ParentLink) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject private var realtimeState: RealtimeState
  @State private var activityState: ComposeActionActivityState

  init(
    title: String,
    minimumHeight: CGFloat,
    peerId: Peer,
    fallback: ChatSubtitle,
    realtimeState: RealtimeState,
    onOpenChatInfo: @escaping () -> Void,
    onOpenSpace: @escaping (ReplyThreadToolbarContext.SpaceLink) -> Void,
    onOpenParentThread: @escaping (ReplyThreadToolbarContext.ParentLink) -> Void
  ) {
    self.title = title
    self.minimumHeight = minimumHeight
    self.peerId = peerId
    self.fallback = fallback
    self.onOpenChatInfo = onOpenChatInfo
    self.onOpenSpace = onOpenSpace
    self.onOpenParentThread = onOpenParentThread
    _realtimeState = ObservedObject(wrappedValue: realtimeState)
    _activityState = State(initialValue: ComposeActions.shared.activityState(for: peerId))
  }

  private var subtitle: ChatSubtitle {
    if let connectionState = realtimeState.displayedConnectionState {
      return .connectionState(connectionState.title.lowercased())
    }

    if let presentation = activityState.presentation {
      if presentation.action == .typing,
         let typingText = ComposeActions.shared.getTypingDisplayText(for: peerId, length: .min),
         !typingText.isEmpty {
        return .composeAction(ComposeActionPresentation(action: .typing, text: typingText))
      }

      return .composeAction(presentation)
    }

    return fallback
  }

  private var subtitleTransition: AnyTransition {
    guard !reduceMotion else { return .opacity }
    return .opacity
      .combined(with: .scale(scale: 0.97, anchor: .leading))
      .combined(with: .offset(y: 3))
  }

  private var subtitleAnimation: Animation? {
    reduceMotion ? nil : .smooth(duration: 0.2)
  }

  var body: some View {
    let subtitle = subtitle

    VStack(alignment: .leading, spacing: 0) {
      Button(action: onOpenChatInfo) {
        Text(title)
          .font(.body)
          .fontWeight(.medium)
          .lineLimit(1)
          .truncationMode(.tail)
          .allowsTightening(true)
      }
      .buttonStyle(ChatToolbarHeaderButtonStyle())
      .accessibilityLabel("Open chat info for \(title)")

      if subtitle != .empty {
        ChatToolbarSubtitleContent(
          subtitle: subtitle,
          onOpenSpace: onOpenSpace,
          onOpenParentThread: onOpenParentThread
        )
        .id(subtitle.transitionID)
        .offset(y: -2)
        .transition(subtitleTransition)
      }
    }
    .frame(minHeight: minimumHeight, alignment: .leading)
    .animation(subtitleAnimation, value: subtitle)
  }
}

private struct ChatToolbarSubtitleContent: View {
  let subtitle: ChatSubtitle
  let onOpenSpace: (ReplyThreadToolbarContext.SpaceLink) -> Void
  let onOpenParentThread: (ReplyThreadToolbarContext.ParentLink) -> Void

  @ViewBuilder
  var body: some View {
    switch subtitle {
    case let .connectionState(text):
      ChatToolbarConnectionSubtitle(text: text)
    case let .composeAction(presentation):
      ChatToolbarComposeActionSubtitle(presentation: presentation)
    case let .timezone(text):
      ChatToolbarTimezoneSubtitle(text: text)
    case let .breadcrumb(context):
      ChatToolbarBreadcrumbSubtitle(
        context: context,
        onOpenSpace: onOpenSpace,
        onOpenParentThread: onOpenParentThread
      )
    case .empty:
      EmptyView()
    }
  }
}

private struct ChatToolbarConnectionSubtitle: View {
  let text: String

  var body: some View {
    ChatToolbarSubtitleText(text: text, color: .secondary)
  }
}

private struct ChatToolbarTimezoneSubtitle: View {
  let text: String

  var body: some View {
    ChatToolbarSubtitleText(text: text, color: .secondary)
  }
}

private struct ChatToolbarSubtitleText: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(color)
      .lineLimit(1)
      .truncationMode(.tail)
      .allowsTightening(true)
  }
}

private struct ChatToolbarComposeActionSubtitle: View {
  let presentation: ComposeActionPresentation

  private var usesAccentColor: Bool {
    presentation.action == .typing || presentation.action == .recordingVoice
  }

  var body: some View {
    HStack(alignment: .center, spacing: 4) {
      ChatToolbarComposeActionIndicator(action: presentation.action)
      ChatToolbarSubtitleText(
        text: presentation.text,
        color: usesAccentColor ? .accentColor : .secondary
      )
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(presentation.text)
  }
}

private struct ChatToolbarComposeActionIndicator: View {
  let action: ApiComposeAction

  @ViewBuilder
  var body: some View {
    switch action {
    case .typing:
      TypingActivityIndicator(color: .accentColor)
    case .uploadingPhoto:
      AnimatedPhotoUpload()
    case .uploadingDocument:
      AnimatedDocumentUpload()
    case .uploadingVideo:
      AnimatedVideoUpload()
    case .recordingVoice:
      VoiceRecordingActivityIndicator(
        barWidth: 2,
        spacing: 2,
        minBarHeight: 3,
        maxBarHeight: 9,
        color: .accentColor
      )
    }
  }
}

private struct ChatToolbarBreadcrumbSubtitle: View {
  let context: ReplyThreadToolbarContext
  let onOpenSpace: (ReplyThreadToolbarContext.SpaceLink) -> Void
  let onOpenParentThread: (ReplyThreadToolbarContext.ParentLink) -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 4) {
      if let space = context.space {
        breadcrumbButton(title: space.title, accessibilityLabel: "Open space \(space.title)") {
          onOpenSpace(space)
        }

        if context.parent != nil {
          Text("/")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }

      if let parent = context.parent {
        breadcrumbButton(title: parent.title, accessibilityLabel: "Open parent chat \(parent.title)") {
          onOpenParentThread(parent)
        }
        .layoutPriority(1)
      }
    }
    .lineLimit(1)
  }

  private func breadcrumbButton(
    title: String,
    accessibilityLabel: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      ChatToolbarSubtitleText(text: title, color: .secondary)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
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
      ChatToolbarSubtitleContent(
        subtitle: subtitle,
        onOpenSpace: { _ in },
        onOpenParentThread: { _ in }
      )
      .offset(y: -2)
    }
    .fixedSize()
  }
}

#Preview {
  VStack(spacing: 20) {
    // Connection States
    ChatSubtitlePreview(subtitle: .connectionState("connecting"))
    ChatSubtitlePreview(subtitle: .connectionState("updating"))
    ChatSubtitlePreview(subtitle: .connectionState("connected"))

    // Typing
    ChatSubtitlePreview(subtitle: .composeAction(.init(action: .typing, text: "John")))
    ChatSubtitlePreview(subtitle: .composeAction(.init(action: .typing, text: "John and Jane")))

    // Compose Actions
    ChatSubtitlePreview(subtitle: .composeAction(.init(action: .uploadingPhoto, text: "uploading photo")))
    ChatSubtitlePreview(subtitle: .composeAction(.init(action: .uploadingDocument, text: "uploading document")))
    ChatSubtitlePreview(subtitle: .composeAction(.init(action: .uploadingVideo, text: "uploading video")))
    ChatSubtitlePreview(subtitle: .composeAction(.init(action: .recordingVoice, text: "recording voice")))

    // Timezone
    ChatSubtitlePreview(subtitle: .timezone("9:41 AM"))

    // Empty
    ChatSubtitlePreview(subtitle: .empty)
  }
  .padding()
  .background(Color(uiColor: .systemBackground))
}
