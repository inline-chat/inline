import Combine
import InlineKit
import InlineUI
import SwiftUI

extension ChatView {
  var isCurrentUser: Bool {
    fullChatViewModel.peerUser?.id == Auth.shared.getCurrentUserId()
  }

  var title: String {
    if case .user = peerId {
      return isCurrentUser ? "Saved Message" : fullChatViewModel.peerUser?.firstName ?? ""
    } else {
      return fullChatViewModel.chat?.title ?? ""
    }
  }

  @ViewBuilder
  var sendButton: some View {
    Button {
      let result = fullChatViewModel.sendMessage(text: text)
      if result == true {
        text = ""
      }

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
