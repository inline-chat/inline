import Combine
import InlineKit
import InlineUI
import Logger
import RealtimeV2
import SwiftUI
import Translation
import UIKit

struct ChatView: View {
  var peerId: Peer
  var contextSpaceId: Int64?
  var preview: Bool
  private let focusMessageID: Int64?
  private let autoCleanupUntitledEmptyThreadOnBack: Bool

  @State var navBarHeight: CGFloat = 0
  @State var isChatHeaderPressed = false
  @State private var pageState: PageState = .initial
  @State private var attemptedUntitledCleanupOnExit = false
  @State private var activeChatToken: MessagesPublisher.ActiveChatToken?
  @State private var isVisible = false
  @State private var userGroupMentionTarget: UserGroupMentionTarget?
  @State private var botChatSettingsCoordinator: BotChatSettingsCoordinator
  @State private var isBotChatSettingsPresented = false
  @State private var translationPlacement: ChatTranslationPlacement
  @State private var presentedChatInfo: SpaceChatItem?
  @Namespace private var chatInfoTransition

  @EnvironmentStateObject var fullChatViewModel: FullChatViewModel

  @EnvironmentObject var data: DataManager

  @Environment(Router.self) var router
  @Environment(\.scenePhase) var scenePhase
  @Environment(\.realtimeV2) var realtimeV2
  @Environment(\.colorScheme) var colorScheme
  @Environment(\.appDatabase) private var appDatabase

  static let formatter = RelativeDateTimeFormatter()

  enum PageState {
    case initial
    case loading
    case loaded
    case error(Error)
  }

  private enum RenderState {
    case content
    case loading
    case error(Error)
  }

  private enum ChatLoadError: LocalizedError {
    case unavailable

    var errorDescription: String? {
      switch self {
        case .unavailable:
          "Chat is not available."
      }
    }
  }

  private enum ChatTranslationPlacement {
    case toolbar
    case moreMenu
  }

  private enum TransitionID: Hashable {
    case chatInfo
  }

  init(
    peer: Peer,
    contextSpaceId: Int64? = nil,
    preview: Bool = false,
    focusMessageID: Int64? = nil,
    autoCleanupUntitledEmptyThreadOnBack: Bool = false
  ) {
    peerId = peer
    self.contextSpaceId = contextSpaceId
    self.preview = preview
    self.focusMessageID = focusMessageID
    self.autoCleanupUntitledEmptyThreadOnBack = autoCleanupUntitledEmptyThreadOnBack
    _botChatSettingsCoordinator = State(initialValue: BotChatSettingsCoordinator(peer: peer))
    _translationPlacement = State(
      initialValue: TranslationState.shared.isTranslationEnabled(for: peer) ? .toolbar : .moreMenu
    )
    _fullChatViewModel = EnvironmentStateObject { env in
      FullChatViewModel(db: env.appDatabase, peer: peer)
    }
  }

  var body: some View {
    ZStack(alignment: .top) {
      chatContent
      ChatViewHeader(navBarHeight: $navBarHeight)
      renderOverlay
    }
    .toolbarColorScheme(colorScheme == .dark ? .dark : .light, for: .navigationBar)
    .toolbarBackground(.hidden, for: .navigationBar)
    .toolbarTitleDisplayMode(.inline)
    .hideTabBarIfNeeded()
    .toolbarRole(.editor)
    .toolbar {
      if translationPlacement == .toolbar {
        ToolbarItem(placement: .primaryAction) {
          TranslationButton(peer: peerId, activeColor: ThemeManager.shared.accentColor)
        }
      }

      ToolbarItem(placement: .primaryAction) {
        ChatToolbarMoreMenu(
          peer: peerId,
          chatId: fullChatViewModel.chat?.id,
          includesTranslationAction: translationPlacement == .moreMenu
        ) {
          guard let chatItem = fullChatViewModel.chatItem else { return }
          presentedChatInfo = chatItem
        }
      }

      if botChatSettingsCoordinator.isToolbarVisible {
        ToolbarItem(placement: .primaryAction) {
          Button {
            isBotChatSettingsPresented = true
          } label: {
            Label("Agent Settings", systemImage: "slider.horizontal.3")
          }
          .accessibilityLabel("Agent Settings")
        }
      }

      if #available(iOS 26.0, *) {
        ToolbarItem(placement: .principal) {
          ChatToolbarLeadingView(
            peerId: peerId,
            contextSpaceId: contextSpaceId,
            isChatHeaderPressed: $isChatHeaderPressed,
            onOpenChatInfo: { presentedChatInfo = $0 }
          )
          .matchedTransitionSource(id: TransitionID.chatInfo, in: chatInfoTransition)
        }
        .sharedBackgroundVisibility(.hidden)
      } else {
        ToolbarItem(placement: .topBarLeading) {
          ChatToolbarLeadingView(
            peerId: peerId,
            contextSpaceId: contextSpaceId,
            isChatHeaderPressed: $isChatHeaderPressed,
            onOpenChatInfo: { presentedChatInfo = $0 }
          )
          .matchedTransitionSource(id: TransitionID.chatInfo, in: chatInfoTransition)
        }
      }
    }
    .task {
      await fetchChatIfNeeded()
    }
    .task(id: focusMessageID) {
      await loadFocusedMessageIfNeeded()
    }
    .task(id: peerId.toString()) {
      botChatSettingsCoordinator.startObservingDiscoveryScope(in: appDatabase)
      await botChatSettingsCoordinator.warmUp()
    }
    .onReceive(TranslationState.shared.subject) { event in
      let (eventPeer, enabled) = event
      guard eventPeer == peerId, enabled, translationPlacement == .moreMenu else { return }
      translationPlacement = .toolbar
    }
    .sheet(isPresented: $isBotChatSettingsPresented) {
      BotChatSettingsSheet(coordinator: botChatSettingsCoordinator)
    }
    .sheet(item: $presentedChatInfo) { chatItem in
      NavigationStack {
        ChatInfoView(chatItem: chatItem, isPresentedModally: true)
      }
      .navigationTransition(.zoom(sourceID: TransitionID.chatInfo, in: chatInfoTransition))
      .presentationDetents([.large])
      .presentationDragIndicator(.hidden)
    }
    .onAppear {
      isVisible = true
      updateMessageUpdateActivation()
    }
    .onChange(of: peerId) { _, newPeer in
      isBotChatSettingsPresented = false
      botChatSettingsCoordinator.cancel()
      botChatSettingsCoordinator = BotChatSettingsCoordinator(peer: newPeer)
      translationPlacement = TranslationState.shared.isTranslationEnabled(for: newPeer) ? .toolbar : .moreMenu
      updateMessageUpdateActivation()
    }
    .onChange(of: fullChatViewModel.chat?.id) { _, chatId in
      guard chatId != nil else { return }
      pageState = .loaded
    }
    .onDisappear {
      isVisible = false
      botChatSettingsCoordinator.cancel()
      updateMessageUpdateActivation()
      scheduleUntitledThreadCleanupIfNeeded()
    }
    .onChange(of: scenePhase) { _, newPhase in
      updateMessageUpdateActivation()
      if newPhase == .active, fullChatViewModel.chat != nil, case .loaded = pageState {
        fullChatViewModel.refetchHistoryOnly()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NavigationBarHeight"))) { notification in
      if let height = notification.userInfo?["navBarHeight"] as? CGFloat {
        navBarHeight = height
      }
    }
    .onReceive(
      NotificationCenter.default
        .publisher(for: Notification.Name("chatDeletedNotification"))
    ) { notification in
      if let chatId = notification.userInfo?["chatId"] as? Int64,
         chatId == fullChatViewModel.chat?.id ?? 0
      {
        router.pop()
      }
    }
    .onReceive(
      NotificationCenter.default
        .publisher(for: Notification.Name("MentionTapped"))
    ) { notification in
      if let userId = notification.userInfo?["userId"] as? Int64 {
        Task {
          // TODO: hacky
          do {
            let peer = try await data.createPrivateChat(userId: userId)
            router.push(.chat(peer: peer))
          } catch {
            Log.shared.error("Failed to create private chat for mention", error: error)
          }
        }
      }
    }
    .onReceive(
      NotificationCenter.default
        .publisher(for: .userGroupMentionTapped)
    ) { notification in
      guard var target = notification.userInfo?["target"] as? UserGroupMentionTarget else { return }
      if target.spaceId == nil {
        target.spaceId = contextSpaceId ?? fullChatViewModel.chat?.spaceId
      }
      userGroupMentionTarget = target
    }
    .sheet(item: $userGroupMentionTarget) { target in
      UserGroupMembersSheet(target: target)
    }
    .onReceive(
      NotificationCenter.default
        .publisher(for: Notification.Name("NavigateToUser"))
    ) { notification in
      if let userId = notification.userInfo?["userId"] as? Int64 {
        router.push(.chat(peer: Peer.user(id: userId)))
      }
    }
    .onReceive(
      NotificationCenter.default
        .publisher(for: Notification.Name("NavigateToForwardedMessage"))
    ) { notification in
      guard let messageId = notification.userInfo?["messageId"] as? Int64 else { return }

      let targetPeer: Peer? = if let userId = notification.userInfo?["peerUserId"] as? Int64 {
        .user(id: userId)
      } else if let threadId = notification.userInfo?["peerThreadId"] as? Int64 {
        .thread(id: threadId)
      } else {
        nil
      }

      guard let targetPeer else { return }

      if targetPeer == peerId, let chatId = fullChatViewModel.chat?.id {
        postScrollToMessage(messageId, chatId: chatId)
        return
      }

      Task { @MainActor in
        if let chat = try? Chat.getByPeerId(peerId: targetPeer) {
          router.push(.chat(peer: targetPeer))
          postScrollToMessage(messageId, chatId: chat.id, delay: 0.25)
          return
        }

        do {
          _ = try await realtimeV2.send(.getChat(peer: targetPeer))
        } catch {
          Log.shared.error("NavigateToForwardedMessage: getChat failed for peer \(targetPeer)", error: error)
        }

        if let chat = try? Chat.getByPeerId(peerId: targetPeer) {
          router.push(.chat(peer: targetPeer))
          postScrollToMessage(messageId, chatId: chat.id, delay: 0.25)
          return
        }

        ToastManager.shared.showToast(
          "You don't have access to that chat",
          type: .error,
          systemImage: "exclamationmark.triangle"
        )
        Log.shared.error("NavigateToForwardedMessage: missing chat for peer \(targetPeer)")
      }
    }
    .onReceive(
      NotificationCenter.default
        .publisher(for: Notification.Name("NavigateToForwardDestination"))
    ) { notification in
      let targetPeer: Peer? = if let userId = notification.userInfo?["peerUserId"] as? Int64 {
        .user(id: userId)
      } else if let threadId = notification.userInfo?["peerThreadId"] as? Int64 {
        .thread(id: threadId)
      } else {
        nil
      }

      guard let targetPeer, targetPeer != peerId else { return }
      router.push(.chat(peer: targetPeer))
    }
    .onReceive(
      NotificationCenter.default
        .publisher(for: .navigateToThreadLink)
    ) { notification in
      let targetPeer: Peer? = if let userId = notification.userInfo?["peerUserId"] as? Int64 {
        .user(id: userId)
      } else if let threadId = notification.userInfo?["peerThreadId"] as? Int64 {
        .thread(id: threadId)
      } else {
        nil
      }

      guard let targetPeer, targetPeer != peerId else { return }
      router.push(.chat(peer: targetPeer))
    }
    .onReceive(
      NotificationCenter.default
        .publisher(for: .navigateToReplyThread)
    ) { notification in
      let targetPeer: Peer? = if let userId = notification.userInfo?["peerUserId"] as? Int64 {
        .user(id: userId)
      } else if let threadId = notification.userInfo?["peerThreadId"] as? Int64 {
        .thread(id: threadId)
      } else {
        nil
      }

      guard let targetPeer, targetPeer != peerId else { return }
      router.push(.chat(peer: targetPeer))
    }
    .onReceive(NotificationCenter.default.publisher(for: .mediaSendFailed)) { notification in
      guard let chatId = notification.userInfo?["chatId"] as? Int64,
            chatId == fullChatViewModel.chat?.id
      else { return }

      let message = notification.userInfo?["message"] as? String ?? "Couldn't send attachment."
      ToastManager.shared.showToast(
        message,
        type: .error,
        systemImage: "exclamationmark.triangle.fill"
      )
    }
    .environmentObject(fullChatViewModel)
    .environment(router)
  }

  @MainActor
  private func postScrollToMessage(
    _ messageId: Int64,
    chatId: Int64,
    delay: TimeInterval = 0
  ) {
    let post = {
      NotificationCenter.default.post(
        name: Notification.Name("ScrollToRepliedMessage"),
        object: nil,
        userInfo: [
          "repliedToMessageId": messageId,
          "chatId": chatId,
        ]
      )
    }

    if delay > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: post)
    } else {
      post()
    }
  }

  @MainActor
  private func updateMessageUpdateActivation() {
    if isVisible, scenePhase == .active {
      activateMessageUpdates()
    } else {
      deactivateMessageUpdates()
    }
  }

  @MainActor
  private func activateMessageUpdates() {
    if let activeChatToken, activeChatToken.peer == peerId { return }
    deactivateMessageUpdates()
    activeChatToken = MessagesPublisher.shared.activateChat(peer: peerId)
  }

  @MainActor
  private func deactivateMessageUpdates() {
    guard let token = activeChatToken else { return }
    MessagesPublisher.shared.deactivateChat(token)
    activeChatToken = nil
  }

  @MainActor
  private func fetchChatIfNeeded() async {
    if fullChatViewModel.chat != nil {
      pageState = .loaded
      fullChatViewModel.refetchHistoryOnly()
      return
    }

    pageState = .loading
    do {
      let chat = try await fullChatViewModel.ensureChat()
      if chat != nil || fullChatViewModel.chat != nil {
        pageState = .loaded
        fullChatViewModel.refetchHistoryOnly()
      } else {
        pageState = .error(ChatLoadError.unavailable)
      }
    } catch {
      if fullChatViewModel.chat != nil {
        pageState = .loaded
      } else {
        pageState = .error(error)
      }
    }
  }

  @ViewBuilder
  private var chatContent: some View {
    if let chat = fullChatViewModel.chat {
      ChatViewUIKit(
        peerId: peerId,
        chatId: chat.id,
        spaceId: chat.spaceId,
        draftMessage: fullChatViewModel.chatItem?.dialog.draftMessage,
        focusMessageID: focusMessageID
      )
      .edgesIgnoringSafeArea(.all)
    }
  }

  @ViewBuilder
  private var renderOverlay: some View {
    switch renderState {
      case .content:
        EmptyView()
      case .loading:
        loadingOverlay
      case let .error(error):
        errorOverlay(error: error)
    }
  }

  private var renderState: RenderState {
    if fullChatViewModel.chat != nil {
      return .content
    }

    switch pageState {
      case .error(let error):
        return .error(error)
      case .initial, .loading, .loaded:
        return .loading
    }
  }

  private var loadingOverlay: some View {
    ZStack {
      Color.black.opacity(0.1)
        .ignoresSafeArea()

      ProgressView()
        .scaleEffect(1.2)
    }
  }

  private func errorOverlay(error: Error) -> some View {
    ZStack {
      Color.black.opacity(0.1)
        .ignoresSafeArea()

      VStack(spacing: 16) {
        Image(systemName: "exclamationmark.triangle")
          .font(.system(size: 48))
          .foregroundColor(.secondary)

        Text("Failed to load chat")
          .font(.headline)

        Text(error.localizedDescription)
          .font(.subheadline)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal)

        Button("Retry") {
          Task { await fetchChatIfNeeded() }
        }
        .buttonStyle(.borderedProminent)
      }
      .padding()
    }
  }

  private func scheduleUntitledThreadCleanupIfNeeded() {
    guard autoCleanupUntitledEmptyThreadOnBack else { return }
    guard case .thread = peerId else { return }
    guard !attemptedUntitledCleanupOnExit else { return }

    Task { @MainActor in
      await Task.yield()
      guard !chatRouteStillPresent else { return }

      attemptedUntitledCleanupOnExit = true
      do {
        _ = try await data.deleteThreadIfUntitledAndEmpty(peerId: peerId)
      } catch {
        Log.shared.error("Failed to cleanup untitled empty thread on exit", error: error)
      }
    }
  }

  private var chatRouteStillPresent: Bool {
    AppTab.allCases.contains { tab in
      router[tab].contains { destination in
        switch destination {
        case let .chat(peer), let .chatMessage(peer, _):
          peer == peerId
        default:
          false
        }
      }
    }
  }

  private func loadFocusedMessageIfNeeded() async {
    guard let focusMessageID else { return }

    do {
      _ = try await realtimeV2.send(
        .getMessages(peer: peerId, messageIds: [focusMessageID])
      )
    } catch is CancellationError {
      return
    } catch {
      Log.shared.error("Failed to load focused message", error: error)
      ToastManager.shared.showToast(
        "Could not load that message",
        type: .error,
        systemImage: "exclamationmark.triangle.fill"
      )
    }
  }
}

private struct ChatToolbarMoreMenu: View {
  let peer: Peer
  let chatId: Int64?
  let includesTranslationAction: Bool
  let openChatInfo: () -> Void

  @Environment(\.realtimeV2) private var realtimeV2
  @State private var transcriptTask: Task<Void, Never>?
  @State private var pendingTranscript: ChatTranscriptExport?
  @State private var showTranscriptScope = false
  @State private var showTranslationPopover = false
  @State private var showTranslationOptions = false

  var body: some View {
    Menu {
      if includesTranslationAction {
        Button("Translate", systemImage: "translate") {
          showTranslationPopover = true
        }
      }

      if peer.isPrivate {
        NudgeButton(
          peer: peer,
          chatId: chatId,
          presentation: .menu
        )
      }

      if includesTranslationAction || peer.isPrivate {
        Divider()
      }

      Button("Chat Info", systemImage: "info.circle", action: openChatInfo)

      if peer.isThread {
        Divider()

        Button("Copy Link", systemImage: "link") {
          copyLink()
        }

        Button("Copy as Markdown", systemImage: "doc.on.doc") {
          prepareTranscript()
        }
        .disabled(transcriptTask != nil)
      }
    } label: {
      Image(systemName: "ellipsis")
    }
    .accessibilityLabel("More")
    .popover(isPresented: $showTranslationPopover, arrowEdge: .bottom) {
      TranslationPopover(
        peer: peer,
        isOptionsSheetPresented: $showTranslationOptions
      )
      .presentationCompactAdaptation(.popover)
    }
    .sheet(isPresented: $showTranslationOptions) {
      TranslationOptions(peer: peer)
    }
    .confirmationDialog(
      "How much should be copied?",
      isPresented: $showTranscriptScope,
      titleVisibility: .visible
    ) {
      if let pendingTranscript {
        Button {
          copyTranscript(pendingTranscript)
        } label: {
          Text("Copy Latest \(pendingTranscript.messageCount) Messages")
        }
        Button("Copy Entire Chat") {
          prepareEntireTranscript(startingWith: pendingTranscript)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This chat has more messages than the default transcript.")
    }
    .onDisappear {
      transcriptTask?.cancel()
    }
  }

  @MainActor
  private func copyLink() {
    guard case let .thread(id) = peer,
          let url = InlineDeepLink.chat(id: id).url
    else {
      ToastManager.shared.showToast(
        "Failed to copy link",
        type: .error,
        systemImage: "exclamationmark.triangle"
      )
      return
    }

    UIPasteboard.general.string = url.absoluteString
    ToastManager.shared.showToast("Copied link", type: .success, systemImage: "link")
  }

  @MainActor
  private func prepareTranscript() {
    guard transcriptTask == nil else { return }
    transcriptTask = Task(priority: .userInitiated) { @MainActor in
      defer { transcriptTask = nil }
      ToastManager.shared.showToast("Preparing…", type: .loading)

      do {
        let transcript = try await ChatTranscriptExporter.latest(peer: peer, realtime: realtimeV2)
        try Task.checkCancellation()
        ToastManager.shared.hideToast()

        if transcript.hasMore {
          pendingTranscript = transcript
          showTranscriptScope = true
        } else {
          copyTranscript(transcript)
        }
      } catch is CancellationError {
        ToastManager.shared.hideToast()
      } catch {
        ToastManager.shared.showToast(
          "Failed to prepare transcript",
          type: .error,
          systemImage: "exclamationmark.triangle"
        )
      }
    }
  }

  @MainActor
  private func prepareEntireTranscript(startingWith latest: ChatTranscriptExport) {
    guard transcriptTask == nil else { return }
    transcriptTask = Task(priority: .userInitiated) { @MainActor in
      defer { transcriptTask = nil }
      ToastManager.shared.showToast("Preparing…", type: .loading)

      do {
        let transcript = try await ChatTranscriptExporter.all(
          peer: peer,
          startingWith: latest,
          realtime: realtimeV2
        )
        try Task.checkCancellation()
        ToastManager.shared.hideToast()
        copyTranscript(transcript)
      } catch is CancellationError {
        ToastManager.shared.hideToast()
      } catch {
        ToastManager.shared.showToast(
          "Failed to prepare transcript",
          type: .error,
          systemImage: "exclamationmark.triangle"
        )
      }
    }
  }

  @MainActor
  private func copyTranscript(_ transcript: ChatTranscriptExport) {
    UIPasteboard.general.string = transcript.markdown
    pendingTranscript = nil
    ToastManager.shared.showToast("Copied as Markdown", type: .success, systemImage: "doc.on.doc")
  }
}
