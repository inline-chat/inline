import InlineKit

/// Common presentation model for sidebar chat- and contact-like rows.
struct ChatListItem: Hashable, Identifiable {
  enum Kind: String, Hashable {
    case thread
    case contact
  }

  struct Identifier: Hashable {
    let kind: Kind
    let rawValue: Int64
  }

  let kind: Kind
  let dialog: Dialog?
  let chat: Chat?
  let user: UserInfo?
  let member: Member?
  let lastMessage: EmbeddedMessage?
  let spaceId: Int64?

  var id: Identifier

  var peerId: Peer? {
    if let dialog {
      return dialog.peerId
    }
    if let member {
      return .user(id: member.userId)
    }
    if let user {
      return .user(id: user.id)
    }
    return nil
  }

  var displayTitle: String {
    user?.user.firstName ??
      user?.user.lastName ??
      user?.user.username ??
      chat?.title ??
      "Chat"
  }

  init(chatItem: HomeChatItem) {
    kind = .thread
    dialog = chatItem.dialog
    chat = chatItem.chat
    user = chatItem.user
    member = nil
    lastMessage = chatItem.lastMessage
    spaceId = chatItem.space?.id
    id = Identifier(kind: .thread, rawValue: chatItem.id)
  }

  init(member: Member, user: UserInfo?) {
    kind = .contact
    dialog = nil
    chat = nil
    self.user = user
    self.member = member
    lastMessage = nil
    spaceId = member.spaceId
    id = Identifier(kind: .contact, rawValue: member.id)
  }

  init(spaceChatItem: SpaceChatItem) {
    kind = .thread
    dialog = spaceChatItem.dialog
    chat = spaceChatItem.chat
    user = spaceChatItem.userInfo
    member = nil
    lastMessage = nil
    spaceId = spaceChatItem.dialog.spaceId
    id = Identifier(kind: .thread, rawValue: spaceChatItem.id)
  }
}
