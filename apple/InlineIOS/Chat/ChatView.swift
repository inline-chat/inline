import Combine
import InlineKit
import InlineUI
import SwiftUI

struct ChatView: View {
  var peerId: Peer
  var preview: Bool

  @State var text: String = ""
  @State var textViewHeight: CGFloat = 36

  @EnvironmentStateObject var fullChatViewModel: FullChatViewModel
  @EnvironmentObject var nav: Navigation
  @EnvironmentObject var data: DataManager
  @EnvironmentObject var ws: WebSocketManager

  @Environment(\.appDatabase) var database
  @Environment(\.scenePhase) var scenePhase

  @ObservedObject var composeActions: ComposeActions = .shared

  func currentComposeAction() -> ApiComposeAction? {
    composeActions.getComposeAction(for: peerId)?.action
  }

  @State var currentTime = Date()

  let timer = Timer.publish(
    every: 60, // 1 minute
    on: .main,
    in: .common
  ).autoconnect()

  static let formatter = RelativeDateTimeFormatter()
  func getLastOnlineText(date: Date?) -> String {
    guard let date else { return "" }

    let diffSeconds = Date().timeIntervalSince(date)
    if diffSeconds < 60 {
      return "last seen just now"
    }

    Self.formatter.dateTimeStyle = .named
    return "last seen \(Self.formatter.localizedString(for: date, relativeTo: Date()))"
  }

  var isPrivateChat: Bool {
    fullChatViewModel.peer.isPrivate
  }

  var subtitle: String {
    // TODO: support threads
    if ws.connectionState == .connecting {
      "connecting..."
    } else if let composeAction = currentComposeAction() {
      composeAction.rawValue
    } else if let online = fullChatViewModel.peerUser?.online {
      online
        ? "online"
        : (
          fullChatViewModel.peerUser?.lastOnline != nil
            ? getLastOnlineText(date: fullChatViewModel.peerUser?.lastOnline) : "offline"
        )
    } else {
      "last seen recently"
    }
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
    ChatViewUIKit(peerId: peerId, chatId: fullChatViewModel.chat?.id ?? 0)
      .edgesIgnoringSafeArea(.all)
      .onReceive(timer) { _ in
        currentTime = Date()
      }
      .toolbar {
        ToolbarItem(placement: .principal) {
          header
        }
        if let user = fullChatViewModel.peerUserInfo {
          ToolbarItem(placement: .topBarTrailing) {
            UserAvatar(userInfo: user)
          }
        }
      }
      .overlay(alignment: .top) {
        if preview {
          header
            .frame(height: 45)
            .frame(maxWidth: .infinity)
            .background(.ultraThickMaterial)
        }
      }
      .navigationBarHidden(false)
      .toolbarRole(.editor)
      .toolbarBackground(.visible, for: .navigationBar)
      .toolbarTitleDisplayMode(.inline)
      .onAppear {
        Task {
          UnreadManager.shared.readAll(peerId, chatId: fullChatViewModel.chat?.id ?? 0)
          await fetch()
        }
      }
      .onChange(of: scenePhase) { _, scenePhase_ in
        switch scenePhase_ {
          case .active:
            Task {
              await fetch()
            }
          default:
            break
        }
      }
      .environmentObject(fullChatViewModel)
  }

  @ViewBuilder
  var header: some View {
    VStack(spacing: 0) {
      Text(title)
        .fontWeight(.semibold)
      if !isCurrentUser, isPrivateChat {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  func fetch() async {
    do {
      try await data.getChatHistory(peerUserId: nil, peerThreadId: nil, peerId: peerId)
    } catch {
      Log.shared.error("Failed to get chat history", error: error)
    }
  }
}

struct CustomButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.8 : 1.0)
      .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
  }
}
