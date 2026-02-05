import InlineKit
import InlineUI
import SwiftUI

struct ChatIcon: View {
  enum PeerType: Equatable {
    case chat(Chat)
    case user(UserInfo)
    case savedMessage(User)

    static func == (lhs: PeerType, rhs: PeerType) -> Bool {
      switch (lhs, rhs) {
        case let (.chat(lhsChat), .chat(rhsChat)):
          return lhsChat.id == rhsChat.id
            && lhsChat.title == rhsChat.title
            && lhsChat.emoji == rhsChat.emoji

        case let (.user(lhsUserInfo), .user(rhsUserInfo)):
          return userNameSignature(lhsUserInfo.user) == userNameSignature(rhsUserInfo.user)
            && profilePhotoId(lhsUserInfo) == profilePhotoId(rhsUserInfo)

        case let (.savedMessage(lhsUser), .savedMessage(rhsUser)):
          return userNameSignature(lhsUser) == userNameSignature(rhsUser)

        default:
          return false
      }
    }

    private static func userNameSignature(_ user: User) -> UserNameSignature {
      UserNameSignature(
        firstName: user.firstName,
        lastName: user.lastName,
        username: user.username,
        phoneNumber: user.phoneNumber,
        email: user.email
      )
    }

    private static func profilePhotoId(_ userInfo: UserInfo) -> String? {
      userInfo.profilePhoto?.first?.id ?? userInfo.user.profileFileId
    }

    private struct UserNameSignature: Hashable {
      let firstName: String?
      let lastName: String?
      let username: String?
      let phoneNumber: String?
      let email: String?
    }
  }

  var peer: PeerType
  var size: CGFloat = 34

  var body: some View {
    switch peer {
      case let .chat(thread):
        InitialsCircle(
          name: thread.title ?? "",
          size: size,
          symbol: "number",
          symbolWeight: .medium,
          emoji: thread.emoji
        )

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

// MARK: - Previews

#if DEBUG
#Preview("Chat Icons") {
  let size: CGFloat = 60

  return ScrollView {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: size + 20))], spacing: 20) {
      // Chat with emoji
      ChatIcon(
        peer: .chat(Chat(
          id: 1,
          date: Date(),
          type: .thread,
          title: "Team Chat",
          spaceId: nil,
          peerUserId: nil,
          lastMsgId: nil,
          emoji: "👥"
        )),
        size: size
      )

      // Chat without emoji
      ChatIcon(
        peer: .chat(Chat(
          id: 2,
          date: Date(),
          type: .thread,
          title: "Project Discussion",
          spaceId: nil,
          peerUserId: nil,
          lastMsgId: nil,
          emoji: nil
        )),
        size: size
      )

      // User avatar
      ChatIcon(
        peer: .user(UserInfo.preview),
        size: size
      )

      // Saved messages
      ChatIcon(
        peer: .savedMessage(User.preview),
        size: size
      )

      // More chat examples with different emojis
      ChatIcon(
        peer: .chat(Chat(
          id: 3,
          date: Date(),
          type: .thread,
          title: "Design Team",
          spaceId: nil,
          peerUserId: nil,
          lastMsgId: nil,
          emoji: "🎨"
        )),
        size: size
      )

      ChatIcon(
        peer: .chat(Chat(
          id: 4,
          date: Date(),
          type: .thread,
          title: "Engineering",
          spaceId: nil,
          peerUserId: nil,
          lastMsgId: nil,
          emoji: "⚙️"
        )),
        size: size
      )
    }
    .padding()
  }
  .frame(width: 400, height: 400)
}

#Preview("Different Sizes") {
  let sizes: [CGFloat] = [24, 32, 40, 48, 60]

  return ScrollView {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 20) {
      ForEach(sizes, id: \.self) { size in
        VStack {
          ChatIcon(
            peer: .chat(Chat(
              id: 1,
              date: Date(),
              type: .thread,
              title: "Team Chat",
              spaceId: nil,
              peerUserId: nil,
              lastMsgId: nil,
              emoji: "👥"
            )),
            size: size
          )
          Text("\(Int(size))pt")
            .font(.caption)
        }
      }
    }
    .padding()
  }
  .frame(width: 400, height: 400)
}
#endif
