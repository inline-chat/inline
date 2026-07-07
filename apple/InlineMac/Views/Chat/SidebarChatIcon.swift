import InlineKit
import InlineUI
import SwiftUI

struct SidebarChatIcon: View, Equatable {
  var peer: ChatIcon.PeerType
  var size: CGFloat = 34

  static func == (lhs: SidebarChatIcon, rhs: SidebarChatIcon) -> Bool {
    lhs.peer == rhs.peer && lhs.size == rhs.size
  }

  var body: some View {
    switch peer {
    case let .chat(chat):
      SidebarThreadIcon(
        emoji: chat.emoji,
        isReplyThread: chat.isReplyThread,
        size: size
      )
    case let .user(userInfo):
      UserAvatar(userInfo: userInfo, size: size)
    }
  }
}
