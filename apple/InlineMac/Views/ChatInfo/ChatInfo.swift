import InlineKit
import InlineUI
import SwiftUI

struct ChatInfo: View {
  @EnvironmentStateObject var fullChat: FullChatViewModel

  var peerId: Peer

  public init(peerId: Peer) {
    self.peerId = peerId
    _fullChat = EnvironmentStateObject { env in
      FullChatViewModel(db: env.appDatabase, peer: peerId, reversed: false)
    }
  }

  var body: some View {
    VStack {
      // Avatar
      icon
        .padding(.top, 16)

      // Text
      Text(fullChat.chatItem?.title ?? "Chat")
        .font(.title)
        .padding(.top, 8)

      // Debug information via list view style inset
      List {
        Section("Debug") {
          Text("Peer ID: \(peerId)")
          Text("Chat ID: \(fullChat.chat?.id ?? 0)")
        }
      }
      .listStyle(.automatic)
      .clipShape(.rect(cornerRadius: 12.0))
    }
    .padding()
    .frame(maxHeight: .infinity, alignment: .top) // This ensures top alignment
  }

  @ViewBuilder
  var icon: some View {
    if let user = fullChat.chatItem?.user {
      ChatIcon(peer: .user(user), size: 100)
    } else if let chat = fullChat.chatItem?.chat {
      ChatIcon(peer: .chat(chat), size: 100)
    } else {
      EmptyView()
    }
  }
}

// TODO: Previews
