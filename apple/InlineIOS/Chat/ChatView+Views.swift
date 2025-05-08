import Auth
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
      isCurrentUser ? "Saved Message" : fullChatViewModel.peerUser?.firstName ?? fullChatViewModel.peerUser?.username ?? fullChatViewModel.peerUser?.email ?? fullChatViewModel.peerUser?.phoneNumber ?? "Invited User"
    } else {
      fullChatViewModel.chat?.title ?? ""
    }
  }
}
