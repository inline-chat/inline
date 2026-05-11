import Auth
import GRDB
import InlineKit

enum ChatRenamePermission {
  static func canRename(peer: Peer, currentUserId: Int64? = Auth.shared.getCurrentUserId(), db: Database) throws -> Bool {
    guard let chatId = peer.asThreadId() else { return false }
    guard let currentUserId else { return false }

    if let chat = try Chat.fetchOne(db, id: chatId) {
      if chat.createdBy == currentUserId {
        return true
      }

      if chat.isPublic == true,
         let spaceId = chat.spaceId
      {
        return try Member
          .filter(Member.Columns.userId == currentUserId)
          .filter(Member.Columns.spaceId == spaceId)
          .filter(Member.Columns.canAccessPublicChats == true)
          .fetchOne(db) != nil
      }
    }

    return try ChatParticipant
      .filter(Column("chatId") == chatId)
      .filter(Column("userId") == currentUserId)
      .fetchOne(db) != nil
  }
}
