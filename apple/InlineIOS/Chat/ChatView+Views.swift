import Combine
import InlineKit
import InlineUI
import SwiftUI
import Auth

extension ChatView {
  var isCurrentUser: Bool {
    fullChatViewModel.peerUser?.id == Auth.shared.getCurrentUserId()
  }

  var title: String {
    if case .user = peerId {
      isCurrentUser ? "Saved Message" : fullChatViewModel.peerUser?.firstName ?? ""
    } else {
      fullChatViewModel.chat?.title ?? ""
    }
  }
}
