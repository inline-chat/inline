import InlineKit
import InlineUI
import SwiftUI
import SwiftUIIntrospect

struct ChatView: View {
  let peerId: Peer

  @EnvironmentStateObject var fullChat: FullChatViewModel
  @EnvironmentObject var data: DataManager

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
    // SwiftUI-based
    messageList

    // // AppKit-based
    // MessagesCollectionView(
    //   onCopy: { copiedText in
    //     print("Copied text: \(copiedText)")
    //   }
    // )
    // .frame(maxWidth: .infinity, maxHeight: .infinity)
    // .environmentObject(fullChat)
  }

  @ViewBuilder
  var messageList: some View {
    ScrollView(.vertical) {
      LazyVStack(pinnedViews: [.sectionFooters]) {
        ForEach(fullChat.messagesInSections) { section in
          Section(footer: DateBadge(date: section.date).flippedUpsideDown()) {
            ForEach(section.messages) { fullMessage in
              MessageView(fullMessage: fullMessage)
                .flippedUpsideDown()
                .id(fullMessage.id)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, minHeight: 0)
    }
    .flippedUpsideDown()
    .introspect(.scrollView, on: .macOS(.v13, .v14, .v15)) { scrollView in
      scrollView.horizontalScrollElasticity = .none
      scrollView.hasHorizontalScroller = false // Add this line
    }
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom, alignment: .center, spacing: nil) {
      compose
    }
  }

  @State private var text: String = ""

  @ViewBuilder
  var compose: some View {
    HStack {
      TextField("Type a message", text: $text)
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 8)
      Button {
        Task {
          do {
            guard let chatId = fullChat.chat?.id else { return }

            print("Sending message to chat \(chatId)")
            print("Sending message to chat \(self.peerId)")

            // Send message
            try await data
              .sendMessage(
                chatId: chatId,
                peerUserId: nil,
                peerThreadId: nil,
                text: text,
                peerId: self.peerId
              )
          } catch {
            Log.shared.error("Failed to send message", error: error)
          }
        }
      } label: {
        Image(systemName: "paperplane")
          .resizable()
          .scaledToFit()
          .frame(width: 20, height: 20)
          .padding(8)
          .background(Color.accentColor)
          .clipShape(Circle())
      }
      .buttonStyle(.plain)
    }
  }

  var body: some View {
    content
      // Hide default title. No way to achieve this without this for now
      .navigationTitle("")
      //      .navigationSubtitle(subtitle)
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

            VStack(alignment: .leading) {
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
          Button {} label: {
            Label("Info", systemImage: "info.circle")
              .help("Chat Info")
          }
        }
      }
  }
}

struct ChatIcon: View {
  enum PeerType {
    case chat(Chat)
    case user(User)
  }

  let size: CGFloat = 34

  var peer: PeerType

  var body: some View {
    switch peer {
    case .chat:
      Image(systemName: "bubble.middle.bottom.fill")
        .resizable()
        .scaledToFit()
        .frame(width: size, height: size)

    case .user(let user):
      UserAvatar(user: user, size: size)
    }
  }
}
