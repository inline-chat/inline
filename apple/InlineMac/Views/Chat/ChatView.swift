import InlineKit
import SwiftUI

struct ChatView: View {
  let peerId: Peer

  @EnvironmentStateObject var fullChat: FullChatViewModel
  @EnvironmentObject var window: MainWindowViewModel

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

  var body: some View {
    Text(title)
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
