import Combine
import InlineKit
import InlineUI
import Logger
import SwiftUI

struct ChatView: View {
  var peerId: Peer
  var preview: Bool

  @State private var navBarHeight: CGFloat = 0
  @State private var showTranslationPopover = false
  @State private var needsTranslation = false
  @State var apiState: RealtimeAPIState = .connecting
  @State var isTranslationEnabled = false

  @EnvironmentStateObject var fullChatViewModel: FullChatViewModel
  @EnvironmentObject var data: DataManager
  @Environment(Router.self) private var router

  @Environment(\.appDatabase) var database
  @Environment(\.scenePhase) var scenePhase
  @Environment(\.realtime) var realtime

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

  // MARK: - Body

  var body: some View {
    ZStack {
      ChatViewUIKit(
        peerId: peerId,
        chatId: fullChatViewModel.chat?.id ?? 0,
        spaceId: fullChatViewModel.chat?.spaceId ?? 0
      )
      .edgesIgnoringSafeArea(.all)

      ChatViewHeader(navBarHeight: $navBarHeight)
    }
    .toolbarBackground(.hidden, for: .navigationBar)
    .toolbarTitleDisplayMode(.inline)
    .toolbar(.hidden, for: .tabBar)
    .toolbarRole(.editor)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        translateButton
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
      getApiState()
      getTranslationState()
      fetch()
    }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NavigationBarHeight"))) { notification in
      if let height = notification.userInfo?["navBarHeight"] as? CGFloat {
        navBarHeight = height
      }
    }
    .onReceive(realtime.apiStatePublisher) { apiState = $0 }
    .onReceive(TranslationDetector.shared.needsTranslation) { result in
      needsTranslation = result.needsTranslation
      if result.needsTranslation {
        if TranslationState.shared.isTranslationEnabled(for: peerId) {
          showTranslationPopover = false
        } else {
          showTranslationPopover = true
        }
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
    .environmentObject(fullChatViewModel)
  }

  @ViewBuilder
  var toolbarLeadingView: some View {
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
        subtitleView
      }
    }
    .scaledToFill()
    .fixedSize()
    .onTapGesture {
      if let chatItem = fullChatViewModel.chatItem {
        router.push(.chatInfo(chatItem: chatItem))
      }
    }
  }

  @ViewBuilder
  var header: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title)
        .font(.body)

      subtitleView
    }
    .fixedSize(horizontal: false, vertical: true)
    .onAppear {
      apiState = realtime.apiState
    }
    .onReceive(realtime.apiStatePublisher, perform: { nextApiState in
      apiState = nextApiState
    })
  }

  @ViewBuilder
  var translationPopover: some View {
    VStack {
      Text(
        "Translate to \(Locale.current.localizedString(forLanguageCode: UserLocale.getCurrentLanguage()) ?? "your language")?"
      )
      HStack(spacing: 12) {
        Button("Translate") {
          isTranslationEnabled = true
          TranslationState.shared.setTranslationEnabled(true, for: fullChatViewModel.peer)
          showTranslationPopover = false
        }

        if needsTranslation {
          Button("Dismiss") {
            TranslationAlertDismiss.shared.dismissForPeer(fullChatViewModel.peer)
            showTranslationPopover = false
          }
          .foregroundStyle(.tertiary)
        }

      }.padding(.top, 4)
    }
  }

  @ViewBuilder
  var translateButton: some View {
    Button {
      isTranslationEnabled.toggle()
      TranslationState.shared.toggleTranslation(for: fullChatViewModel.peer)
      showTranslationPopover = false
    } label: {
      Image(systemName: "translate")
    }
    .tint(isTranslationEnabled ? ThemeManager.shared.accentColor : .primary.opacity(0.7))
    .popover(isPresented: $showTranslationPopover) {
      translationPopover
        .padding()
        .presentationCompactAdaptation(.popover)
    }
    .onChange(of: showTranslationPopover) { _, isPresented in
      if !isPresented {
        needsTranslation = false
      }
    }
  }

  func getApiState() {
    apiState = realtime.apiState
  }

  func getTranslationState() {
    isTranslationEnabled = TranslationState.shared.isTranslationEnabled(for: peerId)
  }

  func fetch() {
    fullChatViewModel.refetchChatView()
  }
}

struct ChatViewHeader: View {
  @Binding private var navBarHeight: CGFloat

  init(navBarHeight: Binding<CGFloat>) {
    _navBarHeight = navBarHeight
  }

  var body: some View {
    VStack {
      VariableBlurView()
        /// +25 to enhance the variant blur effect; it needs more space to cover the full navigation bar background
        .frame(height: navBarHeight + 38)
        .contentShape(Rectangle())
        .background(
          LinearGradient(
            gradient: Gradient(colors: [
              ThemeManager.shared.backgroundColorSwiftUI.opacity(1),
              ThemeManager.shared.backgroundColorSwiftUI.opacity(0.0),
            ]),
            startPoint: .top,
            endPoint: .bottom
          )
        )
      Spacer()
    }
    .ignoresSafeArea(.all)
  }
}
