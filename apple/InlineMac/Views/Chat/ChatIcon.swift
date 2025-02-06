import InlineKit
import InlineUI
import SwiftUI

struct ChatIcon: View {
  enum PeerType {
    case chat(Chat)
    case user(UserInfo)
    case savedMessage(User)
  }

  var peer: PeerType
  var size: CGFloat = 34

  var body: some View {
    switch peer {
      case let .chat(thread):
        InitialsCircle(name: thread.title ?? "", size: size, symbol: "bubble.fill")

      // raw icon
//        HStack {
//          Image(systemName: "bubble.fill")
//            .resizable()
//            .scaledToFit()
//            .frame(width: size - 6.0, height: size - 6.0)
//            .fixedSize()
//        }
//        .frame(width: size, height: size)
//        .fixedSize()

      case let .user(userInfo):
        UserAvatar(userInfo: userInfo, size: size)

      case let .savedMessage(user):
        InitialsCircle(name: user.firstName ?? user.username ?? "", size: size, symbol: "bookmark.fill")
    }
  }
}
