import SwiftUI
import InlineKit
import InlineUI

struct ChatIcon: View {
  enum PeerType {
    case chat(Chat)
    case user(User)
  }

  let size: CGFloat = 34

  var peer: PeerType

  var body: some View {
    switch peer {
    case .chat:
      Image(systemName: "bubble.middle.bottom.fill")
        .resizable()
        .scaledToFit()
        .frame(width: size, height: size)

    case .user(let user):
      UserAvatar(user: user, size: size)
    }
  }
}
