import Foundation
import GRDB
import InlineKit

struct PreparedChatPayload: Sendable {
  let peer: Peer
  let chatItem: SpaceChatItem?
  let messagesInitialState: MessagesProgressiveViewModel.InitialState
}

actor ChatOpenPreloader {
  static let shared = ChatOpenPreloader()

  private enum MessageDirection {
    case older
    case newer
  }

  func prepare(peer: Peer, database: AppDatabase) async throws -> PreparedChatPayload {
    let initialLimit = await MainActor.run {
      MessagesProgressiveViewModel.defaultInitialLimit()
    }

    return try await database.reader.read { db in
      let chatItem = try Self.fetchChatItem(peer: peer, db: db)
      let messages = try Self.fetchInitialMessages(peer: peer, limit: initialLimit, db: db)

      let messageIds = messages.map(\.message.messageId)
      let oldestLoadedMessageId = messageIds.min()
      let newestLoadedMessageId = messageIds.max()

      let canLoadOlderFromLocal = try Self.hasLocalMessages(
        peer: peer,
        referenceMessageId: oldestLoadedMessageId,
        direction: .older,
        db: db
      )
      let canLoadNewerFromLocal = try Self.hasLocalMessages(
        peer: peer,
        referenceMessageId: newestLoadedMessageId,
        direction: .newer,
        db: db
      )

      let messagesInitialState = MessagesProgressiveViewModel.InitialState(
        messages: messages,
        oldestLoadedMessageId: oldestLoadedMessageId,
        newestLoadedMessageId: newestLoadedMessageId,
        canLoadOlderFromLocal: canLoadOlderFromLocal,
        canLoadNewerFromLocal: canLoadNewerFromLocal
      )

      return PreparedChatPayload(
        peer: peer,
        chatItem: chatItem,
        messagesInitialState: messagesInitialState
      )
    }
  }

  private static func fetchChatItem(peer: Peer, db: Database) throws -> SpaceChatItem? {
    switch peer {
      case .user:
        return try Dialog
          .spaceChatItemQueryForUser()
          .filter(id: Dialog.getDialogId(peerId: peer))
          .fetchOne(db)

      case .thread:
        return try Dialog
          .spaceChatItemQueryForChat()
          .filter(id: Dialog.getDialogId(peerId: peer))
          .fetchOne(db)
    }
  }

  private static func fetchInitialMessages(peer: Peer, limit: Int, db: Database) throws -> [FullMessage] {
    var query = FullMessage.queryRequest()
    switch peer {
      case let .thread(id):
        query = query.filter(Column("peerThreadId") == id)
      case let .user(id):
        query = query.filter(Column("peerUserId") == id)
    }

    let batch = try query
      .order(Column("date").desc, Column("messageId").desc)
      .limit(limit)
      .fetchAll(db)

    return batch.reversed()
  }

  private static func hasLocalMessages(
    peer: Peer,
    referenceMessageId: Int64?,
    direction: MessageDirection,
    db: Database
  ) throws -> Bool {
    guard let referenceMessageId else { return false }

    var query = Message.all()
    switch peer {
      case let .thread(id):
        query = query.filter(Message.Columns.peerThreadId == id)
      case let .user(id):
        query = query.filter(Message.Columns.peerUserId == id)
    }

    query = switch direction {
      case .older:
        query.filter(Message.Columns.messageId < referenceMessageId)
      case .newer:
        query.filter(Message.Columns.messageId > referenceMessageId)
    }

    return try query.limit(1).fetchCount(db) > 0
  }
}
