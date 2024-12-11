import InlineKit
import InlineUI
import SwiftUI
import SwiftUIIntrospect

struct ChatView: View {
  let peerId: Peer

  @EnvironmentObject var data: DataManager
  @EnvironmentObject var nav: NavigationModel
  @EnvironmentStateObject var fullChat: FullChatViewModel

  var item: SpaceChatItem? {
    fullChat.chatItem
  }

  var title: String {
    item?.title ?? "Chat"
  }

  var subtitle: String {
    "online"
  }

  public init(peerId: Peer) {
    self.peerId = peerId
    _fullChat = EnvironmentStateObject { env in
      FullChatViewModel(db: env.appDatabase, peer: peerId, reversed: false)
    }
  }

  @ViewBuilder
  var content: some View {
    GeometryReader { geo in
      VStack(spacing: 0) {
        MessagesList(width: geo.size.width)

        compose
      }
      // So the scroll bar goes under the toolbar
      .ignoresSafeArea(.container, edges: .top)
    }
    .task {
      await fetch()
    }
    .environmentObject(fullChat)
  }

  @State var scrollProxy: ScrollViewProxy? = nil

  @ViewBuilder
  var compose: some View {
    Compose(
      chatId: fullChat.chat?.id,
      peerId: peerId,
      topMsgId: fullChat.topMessage?.message.messageId
    )
  }

  var body: some View {
    content
      // Hide default title. No way to achieve this without this for now
      .navigationTitle("")
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
