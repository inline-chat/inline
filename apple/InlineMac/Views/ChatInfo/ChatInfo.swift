import InlineKit
import InlineUI
import SwiftUI

struct ChatInfo: View {
  @EnvironmentStateObject var fullChat: FullChatViewModel

  var peerId: Peer

  public init(peerId: Peer) {
    self.peerId = peerId
    _fullChat = EnvironmentStateObject { env in
      FullChatViewModel(db: env.appDatabase, peer: peerId)
    }
  }

  var body: some View {
    ScrollView {
      VStack {
        // Avatar
        icon
          .padding(.top, 16)

        // Text
        Text(fullChat.chatItem?.title ?? "Chat")
          .font(.title)
          .padding(.top, 8)

        // Debug information via list view style inset
        Form {
          Section("Debug") {
            LabeledContent("Peer ID") {
              Text("\(peerId)")
            }
            LabeledContent("Chat ID") {
              Text("\(fullChat.chat?.id ?? 0)")
            }
          }
        }
        .formStyle(.grouped)
      }
    }
    .frame(alignment: .top) // This ensures top alignment
  }

  @ViewBuilder
  var icon: some View {
    if let userInfo = fullChat.chatItem?.userInfo {
      ChatIcon(peer: .user(userInfo), size: 100)
    } else if let chat = fullChat.chatItem?.chat {
      ChatIcon(peer: .chat(chat), size: 100)
    } else {
      EmptyView()
    }
  }
}

// TODO: Previews
