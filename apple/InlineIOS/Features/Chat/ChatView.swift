import Auth
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
  private let preview: Bool
  private let focusMessageID: Int64?
  private let autoCleanupUntitledEmptyThreadOnBack: Bool

  @AppStorage(ChatToolbarBackgroundMode.key)
  private var toolbarBackgroundMode = ChatToolbarBackgroundMode.initialValue
  @State var navBarHeight: CGFloat = 0
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
  @EnvironmentObject private var notificationSettings: NotificationSettingsManager
  @EnvironmentObject private var realtimeState: RealtimeState

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

  private enum ChatLoadError: Error {
    case unavailable
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
      if !preview {
        if #available(iOS 27.0, *), toolbarBackgroundMode == .hard {
          ChatToolbarHardBackgroundView(navBarHeight: $navBarHeight)
        } else {
          ChatViewHeader(navBarHeight: $navBarHeight)
        }
      }
      renderOverlay
    }
    .toolbarColorScheme(colorScheme == .dark ? .dark : .light, for: .navigationBar)
    .toolbarBackground(.hidden, for: .navigationBar)
    .toolbarTitleDisplayMode(.inline)
    .hideTabBarIfNeeded(!preview)
    .toolbarRole(.editor)
    .toolbar {
      if !preview {
        if translationPlacement == .toolbar {
          ToolbarItem(placement: .primaryAction) {
            TranslationButton(peer: peerId, activeColor: ThemeManager.shared.accentColor)
          }
        }

        ToolbarItem(placement: .primaryAction) {
          ChatToolbarMoreMenuHost(
            peer: peerId,
            chat: fullChatViewModel.chat,
            dialog: fullChatViewModel.chatItem?.dialog,
            includesTranslationAction: translationPlacement == .moreMenu,
            router: router,
            realtimeV2: realtimeV2,
            notificationSettings: notificationSettings,
            database: appDatabase,
            currentUserId: Auth.shared.getCurrentUserId(),
          ) {
            guard let chatItem = fullChatViewModel.chatItem else { return }
            presentedChatInfo = chatItem
          }
          .id("\(fullChatViewModel.chat?.id ?? 0):\(fullChatViewModel.chat?.spaceId ?? 0)")
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
              router: router,
              fullChatViewModel: fullChatViewModel,
              realtimeState: realtimeState,
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
              router: router,
              fullChatViewModel: fullChatViewModel,
              realtimeState: realtimeState,
              onOpenChatInfo: { presentedChatInfo = $0 }
            )
            .matchedTransitionSource(id: TransitionID.chatInfo, in: chatInfoTransition)
          }
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
      guard !preview else { return }
      botChatSettingsCoordinator.startObservingDiscoveryScope(in: appDatabase)
      await botChatSettingsCoordinator.warmUp()
    }
    .onReceive(TranslationState.shared.subject) { event in
      let (eventPeer, enabled) = event
      guard !preview,
            eventPeer == peerId,
            enabled,
            translationPlacement == .moreMenu
      else { return }
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
      guard !preview else { return }
      isVisible = true
      updateMessageUpdateActivation()
    }
    .onChange(of: peerId) { _, newPeer in
      guard !preview else { return }
      isBotChatSettingsPresented = false
      botChatSettingsCoordinator.cancel()
      botChatSettingsCoordinator = BotChatSettingsCoordinator(peer: newPeer)
      translationPlacement = TranslationState.shared.isTranslationEnabled(for: newPeer) ? .toolbar : .moreMenu
      updateMessageUpdateActivation()
    }
    .onChange(of: router.presentationResetRevision) { _, _ in
      handlePresentationReset()
    }
    .onChange(of: fullChatViewModel.chat?.id) { _, chatId in
      guard chatId != nil else { return }
      pageState = .loaded
    }
    .onDisappear {
      guard !preview else { return }
      isVisible = false
      botChatSettingsCoordinator.cancel()
      updateMessageUpdateActivation()
      scheduleUntitledThreadCleanupIfNeeded()
    }
    .onChange(of: scenePhase) { _, newPhase in
      handleScenePhaseChange(newPhase)
    }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NavigationBarHeight"))) { notification in
      guard !preview else { return }
      if let height = notification.userInfo?["navBarHeight"] as? CGFloat {
        navBarHeight = height
      }
    }
    .onReceive(
      NotificationCenter.default
        .publisher(for: Notification.Name("chatDeletedNotification"))
    ) { notification in
      guard !preview else { return }
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
      guard !preview else { return }
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
      handleUserGroupMention(notification)
    }
    .sheet(item: $userGroupMentionTarget) { target in
      UserGroupMembersSheet(target: target)
    }
    .onReceive(
      NotificationCenter.default
        .publisher(for: Notification.Name("NavigateToUser"))
    ) { notification in
      guard !preview else { return }
      if let userId = notification.userInfo?["userId"] as? Int64 {
        router.push(.chat(peer: Peer.user(id: userId)))
      }
    }
    .onReceive(
      NotificationCenter.default
        .publisher(for: Notification.Name("NavigateToForwardedMessage"))
    ) { notification in
      guard !preview else { return }
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
      guard !preview else { return }
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
      guard !preview else { return }
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
      guard !preview else { return }
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
      handleMediaSendFailure(notification)
    }
    .environmentObject(fullChatViewModel)
    .environment(router)
  }

  private func handleScenePhaseChange(_ newPhase: ScenePhase) {
    updateMessageUpdateActivation()
    guard !preview,
          newPhase == .active,
          fullChatViewModel.chat != nil,
          case .loaded = pageState
    else { return }
    fullChatViewModel.refetchHistoryOnly()
  }

  private func handlePresentationReset() {
    guard !preview, router.selectedTabPath.last?.chatPeer == peerId else { return }
    isBotChatSettingsPresented = false
    presentedChatInfo = nil
    userGroupMentionTarget = nil
  }

  private func handleMediaSendFailure(_ notification: Notification) {
    guard !preview else { return }
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

  private func handleUserGroupMention(_ notification: Notification) {
    guard !preview else { return }
    guard var target = notification.userInfo?["target"] as? UserGroupMentionTarget else { return }
    if target.spaceId == nil {
      target.spaceId = contextSpaceId ?? fullChatViewModel.chat?.spaceId
    }
    userGroupMentionTarget = target
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
    if !preview, isVisible, scenePhase == .active {
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
      if !preview {
        fullChatViewModel.refetchHistoryOnly()
      }
      return
    }

    pageState = .loading
    do {
      let chat = try await fullChatViewModel.ensureChat()
      if chat != nil || fullChatViewModel.chat != nil {
        pageState = .loaded
        if !preview {
          fullChatViewModel.refetchHistoryOnly()
        }
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
        focusMessageID: focusMessageID,
        collapsedMaxId: fullChatViewModel.chatItem?.dialog.collapsedMaxId,
        isPreview: preview
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

  private func errorOverlay(error _: Error) -> some View {
    ZStack {
      Color.black.opacity(0.1)
        .ignoresSafeArea()

      VStack(spacing: 16) {
        Image(systemName: "exclamationmark.triangle")
          .font(.system(size: 48))
          .foregroundColor(.secondary)

        Text("Chat unavailable")
          .font(.headline)

        Text("You may not have access to this chat, or it may no longer exist.")
          .font(.subheadline)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal)

        Button("Try Again") {
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
        case let .chat(peer), let .externalChat(peer, _), let .chatMessage(peer, _):
          peer == peerId
        default:
          false
        }
      }
    }
  }

  private func loadFocusedMessageIfNeeded() async {
    guard !preview, let focusMessageID else { return }

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

private struct ChatToolbarMoreMenuHost: View {
  let peer: Peer
  let chat: Chat?
  let dialog: Dialog?
  let includesTranslationAction: Bool
  let router: Router
  let realtimeV2: RealtimeV2
  let notificationSettings: NotificationSettingsManager
  let database: AppDatabase
  let currentUserId: Int64?
  let openChatInfo: () -> Void

  @ViewBuilder
  var body: some View {
    if let chat, chat.type == .thread, let spaceID = chat.spaceId {
      ChatToolbarObservedVisibilityMenu(
        peer: peer,
        chat: chat,
        dialog: dialog,
        includesTranslationAction: includesTranslationAction,
        router: router,
        realtimeV2: realtimeV2,
        notificationSettings: notificationSettings,
        database: database,
        currentUserId: currentUserId,
        openChatInfo: openChatInfo,
        spaceID: spaceID
      )
      .id("\(chat.id):\(spaceID)")
    } else {
      ChatToolbarMoreMenu(
        peer: peer,
        chat: chat,
        dialog: dialog,
        includesTranslationAction: includesTranslationAction,
        router: router,
        realtimeV2: realtimeV2,
        notificationSettings: notificationSettings,
        database: database,
        currentUserId: currentUserId,
        openChatInfo: openChatInfo,
        visibilityMembership: nil
      )
    }
  }
}

private struct ChatToolbarObservedVisibilityMenu: View {
  let peer: Peer
  let chat: Chat
  let dialog: Dialog?
  let includesTranslationAction: Bool
  let router: Router
  let realtimeV2: RealtimeV2
  let notificationSettings: NotificationSettingsManager
  let database: AppDatabase
  let currentUserId: Int64?
  let openChatInfo: () -> Void

  @StateObject private var membershipStatus: SpaceMembershipStatusViewModel

  init(
    peer: Peer,
    chat: Chat,
    dialog: Dialog?,
    includesTranslationAction: Bool,
    router: Router,
    realtimeV2: RealtimeV2,
    notificationSettings: NotificationSettingsManager,
    database: AppDatabase,
    currentUserId: Int64?,
    openChatInfo: @escaping () -> Void,
    spaceID: Int64
  ) {
    self.peer = peer
    self.chat = chat
    self.dialog = dialog
    self.includesTranslationAction = includesTranslationAction
    self.router = router
    self.realtimeV2 = realtimeV2
    self.notificationSettings = notificationSettings
    self.database = database
    self.currentUserId = currentUserId
    self.openChatInfo = openChatInfo
    _membershipStatus = StateObject(wrappedValue: SpaceMembershipStatusViewModel(
      db: database,
      spaceId: spaceID
    ))
  }

  var body: some View {
    ChatToolbarMoreMenu(
      peer: peer,
      chat: chat,
      dialog: dialog,
      includesTranslationAction: includesTranslationAction,
      router: router,
      realtimeV2: realtimeV2,
      notificationSettings: notificationSettings,
      database: database,
      currentUserId: currentUserId,
      openChatInfo: openChatInfo,
      visibilityMembership: membershipStatus.membership
    )
    .task {
      await membershipStatus.refreshIfNeeded()
    }
  }
}

private struct ChatToolbarMoreMenu: View {
  let peer: Peer
  let chat: Chat?
  let dialog: Dialog?
  let includesTranslationAction: Bool
  // Resolve this above the UIKit toolbar host. A required typed-environment lookup here can
  // transiently lose its value while the navigation bar reattaches during foregrounding.
  let router: Router
  let realtimeV2: RealtimeV2
  @ObservedObject var notificationSettings: NotificationSettingsManager
  let database: AppDatabase
  let currentUserId: Int64?
  let openChatInfo: () -> Void
  let visibilityMembership: Member?

  @State private var transcriptTask: Task<Void, Never>?
  @State private var pendingTranscript: ChatTranscriptExport?
  @State private var showTranscriptScope = false
  @State private var showTranslationPopover = false
  @State private var showTranslationOptions = false
  @State private var showMakePublicAlert = false
  @State private var showMakePrivateSheet = false

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
          chatId: chat?.id,
          presentation: .menu
        )
      }

      if includesTranslationAction || peer.isPrivate {
        Divider()
      }

      Button("Chat Info", systemImage: "info.circle", action: openChatInfo)

      if canChangeVisibility, let chat {
        Button(
          chat.isPublic == true ? "Make Private" : "Make Public",
          systemImage: chat.isPublic == true ? "lock.fill" : "person.2.fill"
        ) {
          if chat.isPublic == true {
            showMakePrivateSheet = true
          } else {
            showMakePublicAlert = true
          }
        }
      }

      Menu {
        DialogNotificationSettingsMenuContent(
          selection: notificationSelectionBinding,
          globalMode: notificationSettings.mode
        )
      } label: {
        Label(
          "Notifications",
          systemImage: DialogNotificationSettingsPresentation.iconName(
            for: notificationSelection,
            globalMode: notificationSettings.mode
          )
        )
      }

      Divider()

      Button("Copy Link", systemImage: "link") {
        copyLink()
      }
      .disabled(chat?.id == nil)

      if peer.isThread {
        Button("Copy as Markdown", systemImage: "doc.on.doc") {
          prepareTranscript()
        }
        .disabled(transcriptTask != nil)
      }

      if let nextPinnedState {
        Divider()

        Button(
          nextPinnedState ? "Pin" : "Unpin",
          systemImage: nextPinnedState ? "pin" : "pin.slash"
        ) {
          updatePinned(nextPinnedState)
        }
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
    .sheet(isPresented: $showMakePrivateSheet) {
      if let chat, let spaceId = chat.spaceId {
        ChatToolbarVisibilityParticipantsSheet(
          chatId: chat.id,
          spaceId: spaceId,
          database: database,
          realtimeV2: realtimeV2,
          currentUserId: currentUserId
        )
      }
    }
    .alert("Make Chat Public", isPresented: $showMakePublicAlert) {
      Button("Cancel", role: .cancel) {}
      Button("Make Public", role: .destructive) {
        updateVisibility(isPublic: true, participantIDs: [])
      }
    } message: {
      Text("Everyone in this space will be able to access this chat. If the space is public, its members and content may be internet-accessible.")
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
    .onChange(of: router.presentationResetRevision) { _, _ in
      guard router.selectedTabPath.last?.chatPeer == peer else { return }
      showTranslationPopover = false
      showTranslationOptions = false
      showMakePrivateSheet = false
      showMakePublicAlert = false
      showTranscriptScope = false
    }
  }

  @MainActor
  private func copyLink() {
    guard let chatId = chat?.id,
          let url = InlineDeepLink.chat(id: chatId).webURL
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

  private var notificationSelection: DialogNotificationSettingSelection {
    dialog?.notificationSelection ?? .global
  }

  private var canChangeVisibility: Bool {
    ChatVisibilityPolicy.canChange(
      chat: chat,
      currentUserId: currentUserId,
      membership: visibilityMembership
    )
  }

  private var notificationSelectionBinding: Binding<DialogNotificationSettingSelection> {
    Binding(
      get: { notificationSelection },
      set: { selection in
        updateNotificationSettings(selection)
      }
    )
  }

  private var nextPinnedState: Bool? {
    guard let dialog else { return nil }
    if dialog.pinned == true { return false }

    let isInboxEligible = dialog.open
      && dialog.archived != true
      && dialog.chatListHidden != true
    return isInboxEligible ? true : nil
  }

  private func updateNotificationSettings(_ selection: DialogNotificationSettingSelection) {
    guard selection != notificationSelection else { return }

    Task(priority: .userInitiated) {
      do {
        _ = try await realtimeV2.send(.updateDialogNotificationSettings(
          peerId: peer,
          selection: selection
        ))
      } catch is CancellationError {
        return
      } catch {
        Log.shared.error("Failed to update dialog notification settings", error: error)
        ToastManager.shared.showToast(
          "Could not update notifications",
          type: .error,
          systemImage: "exclamationmark.triangle"
        )
      }
    }
  }

  private func updateVisibility(isPublic: Bool, participantIDs: [Int64]) {
    guard let chat else { return }

    Task(priority: .userInitiated) {
      do {
        _ = try await realtimeV2.send(.updateChatVisibility(
          chatID: chat.id,
          isPublic: isPublic,
          participantIDs: participantIDs
        ))
      } catch is CancellationError {
        return
      } catch {
        Log.shared.error("Failed to update chat visibility", error: error)
        ToastManager.shared.showToast(
          "Could not update chat visibility",
          type: .error,
          systemImage: "exclamationmark.triangle"
        )
      }
    }
  }

  private func updatePinned(_ pinned: Bool) {
    Task(priority: .userInitiated) {
      do {
        _ = try await realtimeV2.send(.updateDialogOrder(
          peerId: peer,
          pinned: pinned
        ))
      } catch is CancellationError {
        return
      } catch {
        Log.shared.error("Failed to update pin state", error: error)
        ToastManager.shared.showToast(
          "Could not update pin",
          type: .error,
          systemImage: "exclamationmark.triangle"
        )
      }
    }
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

private struct ChatToolbarVisibilityParticipantsSheet: View {
  let chatId: Int64
  let realtimeV2: RealtimeV2
  let currentUserId: Int64?

  @StateObject private var spaceViewModel: SpaceFullMembersViewModel
  @State private var selectedParticipants: Set<Int64>
  @State private var isUpdating = false

  @Environment(\.dismiss) private var dismiss

  init(
    chatId: Int64,
    spaceId: Int64,
    database: AppDatabase,
    realtimeV2: RealtimeV2,
    currentUserId: Int64?
  ) {
    self.chatId = chatId
    self.realtimeV2 = realtimeV2
    self.currentUserId = currentUserId
    _spaceViewModel = StateObject(wrappedValue: SpaceFullMembersViewModel(
      db: database,
      spaceId: spaceId
    ))
    _selectedParticipants = State(initialValue: Set(
      currentUserId.map { [$0] } ?? []
    ))
  }

  var body: some View {
    ChatVisibilityParticipantsSheet(
      spaceViewModel: spaceViewModel,
      selectedParticipants: $selectedParticipants,
      currentUserId: currentUserId,
      onConfirm: makePrivate,
      onCancel: { dismiss() }
    )
  }

  private func makePrivate() {
    guard !isUpdating else { return }
    isUpdating = true

    var participantIDs = selectedParticipants
    if let currentUserId {
      participantIDs.insert(currentUserId)
    }

    Task(priority: .userInitiated) {
      do {
        _ = try await realtimeV2.send(.updateChatVisibility(
          chatID: chatId,
          isPublic: false,
          participantIDs: Array(participantIDs)
        ))
        dismiss()
      } catch is CancellationError {
        return
      } catch {
        isUpdating = false
        Log.shared.error("Failed to make chat private", error: error)
        ToastManager.shared.showToast(
          "Could not make chat private",
          type: .error,
          systemImage: "exclamationmark.triangle"
        )
      }
    }
  }
}
