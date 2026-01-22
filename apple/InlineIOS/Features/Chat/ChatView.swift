import Combine
import GRDB
import InlineKit
import InlineUI
import Logger
import RealtimeV2
import SwiftUI
import Translation

struct ChatView: View {
  var peerId: Peer
  var preview: Bool

  @State var navBarHeight: CGFloat = 0
  @State var isChatHeaderPressed = false
  @State private var pageState: PageState = .initial

  @EnvironmentStateObject var fullChatViewModel: FullChatViewModel

  @EnvironmentObject var data: DataManager

  @Environment(Router.self) var router
  @Environment(\.appDatabase) var database
  @Environment(\.scenePhase) var scenePhase
  @Environment(\.realtime) var realtime
  @Environment(\.colorScheme) var colorScheme

  static let formatter = RelativeDateTimeFormatter()

  enum PageState {
    case initial
    case loading
    case loaded
    case error(Error)
  }

  init(peer: Peer, preview: Bool = false) {
    peerId = peer
    self.preview = preview
    _fullChatViewModel = EnvironmentStateObject { env in
      FullChatViewModel(db: env.appDatabase, peer: peer)
    }
  }

  var body: some View {
    ZStack(alignment: .top) {
      if let chat = fullChatViewModel.chat {
        ChatViewUIKit(
          peerId: peerId,
          chatId: chat.id,
          spaceId: chat.spaceId ?? 0
        )
        .edgesIgnoringSafeArea(.all)
      }

      ChatViewHeader(navBarHeight: $navBarHeight)

      if case .loading = pageState {
        loadingOverlay
      }

      if case let .error(error) = pageState {
        errorOverlay(error: error)
      }
    }
    .toolbarColorScheme(colorScheme == .dark ? .dark : .light, for: .navigationBar)
    .toolbarBackground(.hidden, for: .navigationBar)
    .toolbarTitleDisplayMode(.inline)
    .toolbar(.hidden, for: .tabBar)
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
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .active, fullChatViewModel.chat != nil {
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

      if let chatItem = fetchSpaceChatItem(for: targetPeer) ?? makeFallbackChatItem(for: targetPeer) {
        router.push(.chatInfo(chatItem: chatItem))
      } else {
        Log.shared.error("NavigateToForwardedMessage: unable to build chat info for peer \(targetPeer)")
      }
    }
    .environmentObject(fullChatViewModel)
    .environment(router)
  }

  private func fetchSpaceChatItem(for peer: Peer) -> SpaceChatItem? {
    do {
      return try database.reader.read { db in
        switch peer {
        case .user:
          return try Dialog
            .spaceChatItemQueryForUser()
            .filter(id: Dialog.getDialogId(peerId: peer))
            .fetchOne(db)
        case .thread:
          return try Dialog
            .spaceChatItemQueryForChat()
            .filter(id: Dialog.getDialogId(peerId: peer))
            .fetchOne(db)
        }
      }
    } catch {
      Log.shared.error("NavigateToForwardedMessage: failed to fetch chat item", error: error)
      return nil
    }
  }

  private func makeFallbackChatItem(for peer: Peer) -> SpaceChatItem? {
    switch peer {
    case let .user(id):
      let dialog = Dialog(optimisticForUserId: id)
      let userInfo = fetchUserInfo(userId: id)
      return SpaceChatItem(
        dialog: dialog,
        chat: nil,
        userInfo: userInfo
      )
    case let .thread(id):
      let chat = Chat(
        id: id,
        date: Date(),
        type: .thread,
        title: nil,
        spaceId: nil
      )
      let dialog = Dialog(optimisticForChat: chat)
      return SpaceChatItem(
        dialog: dialog,
        chat: chat,
        userInfo: nil
      )
    }
  }

  private func fetchUserInfo(userId: Int64) -> UserInfo? {
    do {
      return try database.reader.read { db in
        guard let user = try User.fetchOne(db, id: userId) else { return nil }
        let photos = try user.photos.fetchAll(db)
        return UserInfo(user: user, profilePhotos: photos)
      }
    } catch {
      Log.shared.error("NavigateToForwardedMessage: failed to fetch user info", error: error)
      return nil
    }
  }

  private func fetchChatIfNeeded() async {
    if fullChatViewModel.chat != nil {
      pageState = .loaded
      fullChatViewModel.refetchHistoryOnly()
    } else {
      pageState = .loading
      do {
        _ = try await fullChatViewModel.ensureChat()
        pageState = .loaded
      } catch {
        pageState = .error(error)
      }
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
          Task {
            pageState = .loading
            do {
              _ = try await fullChatViewModel.ensureChat()
              pageState = .loaded
            } catch {
              pageState = .error(error)
            }
          }
        }
        .buttonStyle(.borderedProminent)
      }
      .padding()
    }
  }
}
