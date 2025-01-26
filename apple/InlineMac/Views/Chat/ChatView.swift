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
    isSavedMsg ? "Saved Messages" : item?.title ?? "Chat"
  }

  var isCurrentUser: Bool {
    item?.user?.isCurrentUser() ?? false
  }

  var isSavedMsg: Bool {
    isCurrentUser
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
  private func getLastOnlineText(date: Date?, _ currentTime: Date) -> String {
    guard let date else { return "" }

    let diffSeconds = currentTime.timeIntervalSince(date)
    if diffSeconds < 59 {
      return "last seen just now"
    }

    Self.formatter.dateTimeStyle = .named
    //    Self.formatter.unitsStyle = .spellOut
    return "last seen \(Self.formatter.localizedString(for: date, relativeTo: Date()))"
  }

  var rendersSubtitle: Bool {
    item?.user != nil && !isSavedMsg
  }

  var subtitle: String {
    // TODO: support threads
    if let composeAction = currentComposeAction() {
      composeAction.rawValue
    } else if let online = item?.user?.online {
      online
        ? "online"
        : (
          item?.user?.lastOnline != nil
            ? getLastOnlineText(date: item?.user?.lastOnline, currentTime) : "offline"
        )
    } else {
      "last seen recently"
    }
  }

  public init(peerId: Peer) {
    self.peerId = peerId
    _fullChat = EnvironmentStateObject { env in
      FullChatViewModel(
        db: env.appDatabase,
        peer: peerId
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
            if let user = fullChat.chatItem?.user, isSavedMsg {
              ChatIcon(peer: .savedMessage(user), size: 30)
            } else if let user = fullChat.chatItem?.user {
              ChatIcon(peer: .user(user), size: 30)
            } else if let chat = fullChat.chatItem?.chat {
              ChatIcon(peer: .chat(chat), size: 30)
            } else {
              // TODO: Handle
            }

            VStack(alignment: .leading, spacing: 0) {
              Text(title)
                .font(.system(size: 14, weight: .medium))
                .padding(.bottom, 0)

              if rendersSubtitle {
                Text(subtitle)
                  .font(.system(size: 12, weight: .regular))
                  .foregroundStyle(.secondary.opacity(0.6))
                  .padding(.top, 1)
              }
            }
            .padding(.leading, 2)
          }
          .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
          .padding(.leading, 6)
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

    // Refetch user info (online, lastSeen)
    if let user = item?.user {
      do {
        try await data.getUser(id: user.id)
      } catch {
        Log.shared.error("Failed to get user info", error: error)
      }
    }
  }
}
