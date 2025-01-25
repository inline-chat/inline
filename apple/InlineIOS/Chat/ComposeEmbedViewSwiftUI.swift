import GRDB
import InlineKit
import SwiftUI

struct ComposeEmbedViewSwiftUI: View {
  var peerId: Peer
  var chatId: Int64
  var messageId: Int64

  @EnvironmentStateObject var viewModel: FullMessageViewModel

  public init(peerId: Peer, chatId: Int64, messageId: Int64) {
    self.peerId = peerId
    self.chatId = chatId
    self.messageId = messageId
    _viewModel = EnvironmentStateObject { env in
      FullMessageViewModel(
        db: env.appDatabase, messageId: messageId, chatId: chatId
      )
    }
  }

  var name: String {
    viewModel.fullMessage?.from?.firstName ?? "User"
  }

  var body: some View {
    VStack(alignment: .leading) {
      HStack {
        Text("Replying to \(name)")
          .fontWeight(.medium)
          .font(.callout)
          .foregroundColor(ColorManager.shared.swiftUIColor)
        Spacer()
        Button(action: {
          ChatState.shared.clearReplyingMessageId(peer: peerId)
        }) {
          Image(systemName: "xmark")
            .foregroundColor(.secondary)
            .font(.body)
        }
      }
      .frame(maxWidth: .infinity)

      Text(viewModel.fullMessage?.message.text ?? "")
        .font(.callout)
        .foregroundColor(.secondary)
    }
    .padding(.horizontal, 16)
    .frame(maxWidth: .infinity)
    .frame(height: ChatContainerView.embedViewHeight)
    .background(Material.thickMaterial)
  }
}
