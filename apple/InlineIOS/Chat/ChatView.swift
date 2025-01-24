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
    guard let date = date else { return "" }

    let diffSeconds = Date().timeIntervalSince(date)
    if diffSeconds < 60 {
      return "last seen just now"
    }

    Self.formatter.dateTimeStyle = .named
    //    Self.formatter.unitsStyle = .spellOut
    return "last seen \(Self.formatter.localizedString(for: date, relativeTo: Date()))"
  }

  var isPrivateChat: Bool {
    fullChatViewModel.chat?.type == .privateChat
  }

  var subtitle: String {
    // TODO: support threads
    if ws.connectionState == .connecting {
      return "connecting..."
    } else if let composeAction = currentComposeAction() {
      return composeAction.rawValue
    } else if let online = fullChatViewModel.peerUser?.online {
      return online
        ? "online"
        : (fullChatViewModel.peerUser?.lastOnline != nil
          ? getLastOnlineText(date: fullChatViewModel.peerUser?.lastOnline) : "offline")
    } else {
      return "last seen recently"
    }
  }

  init(peer: Peer, preview: Bool = false) {
    self.peerId = peer
    self.preview = preview
    _fullChatViewModel = EnvironmentStateObject { env in
      FullChatViewModel(db: env.appDatabase, peer: peer)
    }
  }

  // MARK: - Body

  var body: some View {
    ChatViewUIKit(peerId: peerId, chatId: fullChatViewModel.chat?.id)
      .edgesIgnoringSafeArea(.all)
      .onReceive(timer) { _ in
        currentTime = Date()
      }
      .toolbar {
        ToolbarItem(placement: .principal) {
          header
        }
        #if DEBUG
        ToolbarItem(placement: .topBarTrailing) {
          if !preview {
            Button(action: {
              Task {
                for i in 1 ... 100 {
                  let _ = Transactions.shared.mutate(
                    transaction: .sendMessage(
                      .init(text: "Test message #\(i)", peerId: peerId, chatId: fullChatViewModel.chat?.id ?? 0)
                    )
                  )

                  try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
                }
              }
            }) {
              Image(systemName: "bolt.fill")
                .foregroundColor(.orange)
            }
          }
        }
        #endif
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
    VStack {
      HStack {
        Text(title)
      }
      if !isCurrentUser && isPrivateChat {
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
