import Combine
import InlineKit
import InlineUI
import Logger
import RealtimeV2
import SwiftUI
import Translation

struct ChatView: View {
  var peerId: Peer
  var preview: Bool
  private let autoCleanupUntitledEmptyThreadOnBack: Bool

  @State var navBarHeight: CGFloat = 0
  @State var isChatHeaderPressed = false
  @State private var pageState: PageState = .initial
  @State private var attemptedUntitledCleanupOnExit = false

  @EnvironmentStateObject var fullChatViewModel: FullChatViewModel

  @EnvironmentObject var data: DataManager

  @Environment(Router.self) var router
  @Environment(\.scenePhase) var scenePhase
  @Environment(\.realtimeV2) var realtimeV2
  @Environment(\.colorScheme) var colorScheme

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

  init(
    peer: Peer,
    preview: Bool = false,
    autoCleanupUntitledEmptyThreadOnBack: Bool = false
  ) {
    peerId = peer
    self.preview = preview
    self.autoCleanupUntitledEmptyThreadOnBack = autoCleanupUntitledEmptyThreadOnBack
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
      if peerId.isPrivate {
        if #available(iOS 26.0, *) {
          ToolbarItem(placement: .primaryAction) {
            NudgeButton(peer: peerId, chatId: fullChatViewModel.chat?.id)
          }
          ToolbarSpacer(.fixed, placement: .primaryAction)
          ToolbarItem(placement: .primaryAction) {
            TranslationButton(peer: peerId)
              .tint(ThemeManager.shared.accentColor)
          }
        } else {
          ToolbarItem(placement: .topBarTrailing) {
            NudgeButton(peer: peerId, chatId: fullChatViewModel.chat?.id)
          }
          ToolbarItem(placement: .primaryAction) {
            TranslationButton(peer: peerId)
              .tint(ThemeManager.shared.accentColor)
          }
        }
      } else {
        ToolbarItem(placement: .primaryAction) {
          TranslationButton(peer: peerId)
            .tint(ThemeManager.shared.accentColor)
        }
      }

      if #available(iOS 26.0, *) {
        ToolbarItem(placement: .principal) {
          ChatToolbarLeadingView(peerId: peerId, isChatHeaderPressed: $isChatHeaderPressed)
        }
        .sharedBackgroundVisibility(.hidden)
      } else {
        ToolbarItem(placement: .topBarLeading) {
          ChatToolbarLeadingView(peerId: peerId, isChatHeaderPressed: $isChatHeaderPressed)
        }
      }
    }
    .task {
      await fetchChatIfNeeded()
    }
    .onChange(of: fullChatViewModel.chat?.id) { _, chatId in
      guard chatId != nil else { return }
      pageState = .loaded
    }
    .onDisappear {
      scheduleUntitledThreadCleanupIfNeeded()
    }
    .onChange(of: scenePhase) { _, newPhase in
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
        NotificationCenter.default.post(
          name: Notification.Name("ScrollToRepliedMessage"),
          object: nil,
          userInfo: ["repliedToMessageId": messageId, "chatId": chatId]
        )
        return
      }

      Task { @MainActor in
        if let chat = try? Chat.getByPeerId(peerId: targetPeer) {
          router.push(.chat(peer: targetPeer))
          let chatId = chat.id
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(
              name: Notification.Name("ScrollToRepliedMessage"),
              object: nil,
              userInfo: ["repliedToMessageId": messageId, "chatId": chatId]
            )
          }
          return
        }

        do {
          _ = try await realtimeV2.send(.getChat(peer: targetPeer))
        } catch {
          Log.shared.error("NavigateToForwardedMessage: getChat failed for peer \(targetPeer)", error: error)
        }

        if let chat = try? Chat.getByPeerId(peerId: targetPeer) {
          router.push(.chat(peer: targetPeer))
          let chatId = chat.id
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(
              name: Notification.Name("ScrollToRepliedMessage"),
              object: nil,
              userInfo: ["repliedToMessageId": messageId, "chatId": chatId]
            )
          }
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
        spaceId: chat.spaceId ?? 0
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
      router[tab].contains(.chat(peer: peerId))
    }
  }
}
