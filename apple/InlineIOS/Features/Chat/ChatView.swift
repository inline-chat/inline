import Combine
import InlineKit
import InlineUI
import Logger
import RealtimeAPI
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

  var isPrivateChat: Bool {
    fullChatViewModel.peer.isPrivate
  }

  var isThreadChat: Bool {
    fullChatViewModel.peer.isThread
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

      VStack {
        VariableBlurView()
          /// +25 to enhance the variant blur effect; it needs more space to cover the full navigation bar background
          .frame(height: navBarHeight + 38)
          .contentShape(Rectangle())
          .background(
            LinearGradient(
              gradient: Gradient(colors: [
                Color(ThemeManager.shared.selected.backgroundColor).opacity(1),
                Color(ThemeManager.shared.selected.backgroundColor).opacity(0.0),
              ]),
              startPoint: .top,
              endPoint: .bottom
            )
          )
        Spacer()
      }
      .ignoresSafeArea(.all)
    }

    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NavigationBarHeight"))) { notification in
      if let height = notification.userInfo?["navBarHeight"] as? CGFloat {
        navBarHeight = height
      }
    }
    .toolbarBackground(.hidden, for: .navigationBar)
    .toolbarTitleDisplayMode(.inline)
    .toolbar(.hidden, for: .tabBar)
    .toolbarRole(.editor)
    .toolbar {
      ToolbarItem(placement: .principal) {
        Button(action: {
          if let chatItem = fullChatViewModel.chatItem {
            router.push(.chatInfo(chatItem: chatItem))
          }
        }) {
          header
        }
        .buttonStyle(.plain)
      }

      ToolbarItem(placement: .topBarLeading) {
        Button {
          isTranslationEnabled.toggle()
          TranslationState.shared.toggleTranslation(for: fullChatViewModel.peer)
          showTranslationPopover = false
        } label: {
          Image(systemName: "translate")
        }
        .tint(isTranslationEnabled ? Color(ThemeManager.shared.selected.accent) : .gray)
        .popover(isPresented: $showTranslationPopover) {
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
          .padding()
          .presentationCompactAdaptation(.popover)
        }
        .onChange(of: showTranslationPopover) { _, isPresented in
          if !isPresented {
            needsTranslation = false
          }
        }
      }

      if let user = fullChatViewModel.peerUserInfo {
        ToolbarItem(placement: .topBarTrailing) {
          Button(action: {
            if let chatItem = fullChatViewModel.chatItem {
              router.push(.chatInfo(chatItem: chatItem))
            }
          }) {
            if isThreadChat {
              Text(
                String(describing: fullChatViewModel.chat?.emoji ?? "💬")
                  .replacingOccurrences(of: "Optional(\"", with: "")
                  .replacingOccurrences(of: "\")", with: "")
              )
              .font(.body)
            } else {
              UserAvatar(userInfo: user, size: 28)
            }
          }
          .buttonStyle(.plain)
        }
      }
    }
    .overlay(alignment: .top) {
      if preview {
        header
          .frame(height: 45)
          .background(.ultraThickMaterial)
      }
    }
    .onAppear {
      isTranslationEnabled = TranslationState.shared.isTranslationEnabled(for: fullChatViewModel.peer)
      fetch()
    }
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
  var header: some View {
    VStack(spacing: 0) {
      Text(title)
        .font(.body)

      subtitleView
    }
    .onAppear {
      apiState = realtime.apiState
    }
    .onReceive(realtime.apiStatePublisher, perform: { nextApiState in
      apiState = nextApiState
    })
  }

  func fetch() {
    fullChatViewModel.refetchChatView()
  }
}
