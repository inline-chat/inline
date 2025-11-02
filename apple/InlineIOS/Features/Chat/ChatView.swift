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

  @State var navBarHeight: CGFloat = 0
  @State var isChatHeaderPressed = false

  @EnvironmentStateObject var fullChatViewModel: FullChatViewModel

  @EnvironmentObject var data: DataManager
  @EnvironmentObject var realtimeState: RealtimeState

  @Environment(Router.self) var router
  @Environment(\.appDatabase) var database
  @Environment(\.scenePhase) var scenePhase
  @Environment(\.realtime) var realtime
  @Environment(\.colorScheme) var colorScheme

  @ObservedObject var composeActions: ComposeActions = .shared

  static let formatter = RelativeDateTimeFormatter()

  var toolbarAvatarSize: CGFloat {
    if #available(iOS 26.0, *) {
      44
    } else {
      32
    }
  }

  var isPrivateChat: Bool {
    fullChatViewModel.peer.isPrivate
  }

  var isThreadChat: Bool {
    fullChatViewModel.peer.isThread
  }

  var chatProfileColors: [Color] {
    let _ = colorScheme
    return [
      Color(.systemGray3).adjustLuminosity(by: 0.2),
      Color(.systemGray5).adjustLuminosity(by: 0),
    ]
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
      ChatViewUIKit(
        peerId: peerId,
        chatId: fullChatViewModel.chat?.id ?? 0,
        spaceId: fullChatViewModel.chat?.spaceId ?? 0
      )
      .edgesIgnoringSafeArea(.all)

      ChatViewHeader(navBarHeight: $navBarHeight)
    }
    .toolbarColorScheme(colorScheme == .dark ? .dark : .light, for: .navigationBar)
    .toolbarBackground(.hidden, for: .navigationBar)
    .toolbarTitleDisplayMode(.inline)
    .toolbar(.hidden, for: .tabBar)
    .toolbarRole(.editor)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        TranslationButton(peer: peerId)
          .tint(ThemeManager.shared.accentColor)
      }

      if #available(iOS 26.0, *) {
        ToolbarItem(placement: .principal) {
          toolbarLeadingView
        }
        .sharedBackgroundVisibility(.hidden)
      } else {
        ToolbarItem(placement: .topBarLeading) {
          toolbarLeadingView
        }
      }
    }
    .onAppear {
      fetch()
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
    .environmentObject(fullChatViewModel)
    .environment(router)
  }

  func fetch() {
    fullChatViewModel.refetchChatView()
  }
}
