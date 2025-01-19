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
}
