import InlineKit
import SwiftUI

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
    "public"
  }

  public init(peerId: Peer) {
    self.peerId = peerId
    _fullChat = EnvironmentStateObject { env in
      FullChatViewModel(db: env.appDatabase, peer: peerId)
    }
  }

  @ViewBuilder
  var content: some View {
    VStack {
      Text(fullChat.chat?.id.description ?? "NO ID")
      List {
        ForEach(fullChat.fullMessages, id: \.id) { message in
          MessageView(message: message.message)
        }
      }

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
          }catch {
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
            ChatIcon()
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
  var body: some View {
    Image(systemName: "person.fill")
      .resizable()
      .scaledToFit()
  }
}
