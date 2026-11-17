import Auth
import GRDB

public enum MessageDeletePolicy {
  /// Mirrors `ensureDeleteAllowed` on the server: in a chat outside a space (a DM or a home
  /// thread) anyone can delete any message; in a space, your own messages, or any as one of its
  /// owners or admins. With the chat unknown, only your own.
  public static func canDelete(message: Message, chat: Chat?, currentUserId: Int64?, membership: Member?) -> Bool {
    guard let currentUserId else { return false }
    let isOwn = message.fromId == currentUserId || message.out == true
    guard let chat else { return isOwn }
    guard let spaceId = chat.spaceId else { return true }
    if isOwn { return true }
    guard membership?.spaceId == spaceId, membership?.userId == currentUserId else { return false }
    return membership?.role == .owner || membership?.role == .admin
  }

  /// Reads the chat and the viewer's space membership once, for checking many messages in it.
  public static func checker(peer: Peer, db: AppDatabase = .shared) -> (Message) -> Bool {
    let currentUserId = Auth.getCurrentUserId()
    let (chat, membership) = (try? db.reader.read { db -> (Chat?, Member?) in
      let chat = try Chat.getByPeerId(db: db, peerId: peer)
      guard let spaceId = chat?.spaceId, let currentUserId else { return (chat, nil) }
      let membership = try Member
        .filter(Member.Columns.spaceId == spaceId && Member.Columns.userId == currentUserId)
        .fetchOne(db)
      return (chat, membership)
    }) ?? (nil, nil)
    return { message in
      canDelete(message: message, chat: chat, currentUserId: currentUserId, membership: membership)
    }
  }
}
