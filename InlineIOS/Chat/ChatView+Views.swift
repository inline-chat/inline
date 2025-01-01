import Combine
import InlineKit
import InlineUI
import SwiftUI

extension ChatView {
  var title: String {
    if case .user = peerId {
      return fullChatViewModel.peerUser?.firstName ?? ""
    } else {
      return fullChatViewModel.chat?.title ?? ""
    }
  }

  @ViewBuilder
  var content: some View {
    MessagesCollectionView(peerId: peerId)
  }

  @ViewBuilder
  var sendButton: some View {
    Button {
      fullChatViewModel.sendMessage(text: text)
    } label: {
      Circle()
        .fill(text.isEmpty ? Color(.systemGray5) : .blue)
        .frame(width: 28, height: 28)
        .overlay {
          Image(systemName: "arrow.up")
            .font(.callout)
            .foregroundStyle(text.isEmpty ? Color(.tertiaryLabel) : .white)
        }
    }

    .buttonStyle(CustomButtonStyle())
  }
}
