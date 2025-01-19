import InlineKit
import InlineUI
import SwiftUI
import SwiftUIIntrospect

struct ChatView: View {
  let peerId: Peer

  @EnvironmentObject var data: DataManager
  @EnvironmentObject var nav: NavigationModel
  @EnvironmentStateObject var fullChat: FullChatViewModel

  @Environment(\.scenePhase) var scenePhase

  // TODO: Optimize
  @ObservedObject var composeActions: ComposeActions = .shared

  var item: SpaceChatItem? {
    fullChat.chatItem
  }

  var title: String {
    item?.title ?? "Chat"
  }

  private func currentComposeAction() -> ApiComposeAction? {
    composeActions.getComposeAction(for: peerId)?.action
  }

  @State private var currentTime = Date()

  let timer = Timer.publish(
    every: 60, // 1 minute
    on: .main,
    in: .common
  ).autoconnect()

  static let formatter = RelativeDateTimeFormatter()
  private func getLastOnlineText(date: Date?) -> String {
    guard let date = date else { return "" }

    let diffSeconds = Date().timeIntervalSince(date)
    if diffSeconds < 60 {
      return "last seen just now"
    }

    Self.formatter.dateTimeStyle = .named
    //    Self.formatter.unitsStyle = .spellOut
    return "last seen \(Self.formatter.localizedString(for: date, relativeTo: Date()))"
  }

  var subtitle: String {
    // TODO: support threads
    if let composeAction = currentComposeAction() {
      return composeAction.rawValue
    } else if let online = item?.user?.online {
      return online
        ? "online"
        : (item?.user?.lastOnline != nil
          ? getLastOnlineText(date: item?.user?.lastOnline) : "offline")
    } else {
      return "last seen recently"
    }
  }

  public init(peerId: Peer) {
    self.peerId = peerId
    _fullChat = EnvironmentStateObject { env in
      FullChatViewModel(
        db: env.appDatabase,
        peer: peerId,
        reversed: false,
        limit: 1,
        fetchesMessages: false
      )
    }
  }

  @ViewBuilder
  var content: some View {
    ChatViewSwiftUI(peerId: peerId)
      // So the scroll bar goes under the toolbar
      .ignoresSafeArea(.all)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  var body: some View {
    content
      // Hide default title. No way to achieve this without this for now
      .navigationTitle(" ")
      .toolbar {
        ToolbarItem(placement: .navigation) {
          HStack {
            if let user = fullChat.chatItem?.user {
              ChatIcon(peer: .user(user))
            } else if let chat = fullChat.chatItem?.chat {
              ChatIcon(peer: .chat(chat))
            } else {
              // TODO: Handle
            }

            VStack(alignment: .leading, spacing: 0) {
              Text(title)
                .font(.headline)
                .padding(.bottom, 0)
              Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.top, 0)
            }
          }
          .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
        }

        // Required to clear up the space for nav title
        ToolbarItem(placement: .principal) {
          Spacer(minLength: 1)
        }

        ToolbarItem(placement: .primaryAction) {
          Button {
            // show info page here
            nav.navigate(to: .chatInfo(peer: peerId))
          } label: {
            Label("Info", systemImage: "info.circle")
              .help("Chat Info")
          }
        }
      }
      .onReceive(timer) { _ in
        currentTime = Date()
      }
      .onAppear {
        // On Appear - temporary
        Task {
          await fetch()
        }
      }
      .onChange(of: scenePhase) { scenePhase_ in
        // Refetch on open - temporary
        switch scenePhase_ {
        case .active:
          Task {
            await fetch()
          }
        default:
          break
        }
      }
      .environmentObject(fullChat)
  }

  /// Fetch chat history
  private func fetch() async {
    do {
      try await data.getChatHistory(peerUserId: nil, peerThreadId: nil, peerId: peerId)
    } catch {
      Log.shared.error("Failed to get chat history", error: error)
    }
  }
}
