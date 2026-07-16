import Auth
import GRDB
import InlineKit

enum ChatRenamePermission {
  static func canRename(peer: Peer, currentUserId: Int64? = Auth.shared.getCurrentUserId(), db: Database) throws -> Bool {
    guard let chatId = peer.asThreadId() else { return false }
    guard let currentUserId else { return false }
    guard let chat = try Chat.fetchOne(db, id: chatId) else { return false }

    if let canUpdateInfo = chat.canUpdateInfo {
      return canUpdateInfo
    }

    if chat.isReplyThread,
       let spaceId = chat.spaceId,
       try isSpaceAdmin(spaceId: spaceId, userId: currentUserId, db: db) {
      return true
    }

    if chat.isReplyThread,
       try hasParticipantGrant(chatId: chat.id, userId: currentUserId, db: db) {
      return true
    }

    guard let accessSource = try inheritedAccessSource(for: chat, db: db) else {
      return false
    }

    if chat.isReplyThread,
       accessSource.id != chat.id,
       try hasParticipantGrant(chatId: accessSource.id, userId: currentUserId, db: db) {
      return true
    }

    if accessSource.isPublic == true,
       let spaceId = accessSource.spaceId {
      return try Member
        .filter(Member.Columns.userId == currentUserId)
        .filter(Member.Columns.spaceId == spaceId)
        .filter(Member.Columns.canAccessPublicChats == true)
        .fetchOne(db) != nil
    }

    return try hasDirectParticipantGrant(chatId: chat.id, userId: currentUserId, db: db)
  }

  private static func isSpaceAdmin(spaceId: Int64, userId: Int64, db: Database) throws -> Bool {
    guard let member = try Member
      .filter(Member.Columns.userId == userId)
      .filter(Member.Columns.spaceId == spaceId)
      .fetchOne(db)
    else {
      return false
    }

    return member.role == .owner || member.role == .admin
  }

  private static func hasParticipantGrant(chatId: Int64, userId: Int64, db: Database) throws -> Bool {
    if try hasDirectParticipantGrant(chatId: chatId, userId: userId, db: db) {
      return true
    }

    let groupIds = try ChatParticipantGroup
      .filter(ChatParticipantGroup.Columns.chatId == chatId)
      .fetchAll(db)
      .map(\.groupId)

    guard !groupIds.isEmpty else { return false }

    return try UserGroupMember
      .filter(groupIds.contains(UserGroupMember.Columns.groupId))
      .filter(UserGroupMember.Columns.userId == userId)
      .fetchOne(db) != nil
  }

  private static func hasDirectParticipantGrant(chatId: Int64, userId: Int64, db: Database) throws -> Bool {
    try ChatParticipant
      .filter(Column("chatId") == chatId)
      .filter(Column("userId") == userId)
      .fetchOne(db) != nil
  }

  private static func inheritedAccessSource(for chat: Chat, db: Database) throws -> Chat? {
    var source = chat
    var seenIds: Set<Int64> = [chat.id]

    while let parentChatId = source.parentChatId {
      guard seenIds.insert(parentChatId).inserted,
            let parent = try Chat.fetchOne(db, id: parentChatId)
      else {
        return nil
      }
      source = parent
    }

    return source
  }
}
