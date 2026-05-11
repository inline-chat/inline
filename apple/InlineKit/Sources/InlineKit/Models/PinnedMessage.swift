import Foundation
import GRDB

public struct PinnedMessage: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable, Identifiable {
  public var id: Int64?
  public var chatId: Int64
  public var messageId: Int64
  public var position: Int64

  public var stableId: Int64 {
    id ?? 0
  }

  public enum Columns {
    public static let id = Column(CodingKeys.id)
    public static let chatId = Column(CodingKeys.chatId)
    public static let messageId = Column(CodingKeys.messageId)
    public static let position = Column(CodingKeys.position)
  }

  public static let chat = belongsTo(Chat.self)
  public var chat: QueryInterfaceRequest<Chat> {
    request(for: PinnedMessage.chat)
  }

  public static let message = belongsTo(
    Message.self,
    using: ForeignKey(["chatId", "messageId"], to: ["chatId", "messageId"])
  )
  public var message: QueryInterfaceRequest<Message> {
    request(for: PinnedMessage.message)
  }

  public init(chatId: Int64, messageId: Int64, position: Int64) {
    self.chatId = chatId
    self.messageId = messageId
    self.position = position
  }
}

public extension PinnedMessage {
  static func isPinned(_ db: Database, chatId: Int64, messageId: Int64) throws -> Bool {
    try filter(Columns.chatId == chatId)
      .filter(Columns.messageId == messageId)
      .fetchCount(db) > 0
  }

  static func replaceAll(_ db: Database, chatId: Int64, messageIds: [Int64]) throws {
    try filter(Columns.chatId == chatId).deleteAll(db)
    try markKnownMessagesPinned(db, chatId: chatId, messageIds: [], pinned: false)

    for (index, messageId) in messageIds.enumerated() {
      let pinned = PinnedMessage(chatId: chatId, messageId: messageId, position: Int64(index))
      try pinned.save(db)
    }

    try markKnownMessagesPinned(db, chatId: chatId, messageIds: messageIds, pinned: true)
  }

  static func pin(_ db: Database, chatId: Int64, messageId: Int64) throws {
    try db.execute(
      sql: "UPDATE pinnedMessage SET position = position + 1 WHERE chatId = ?",
      arguments: [chatId]
    )

    let pinned = PinnedMessage(chatId: chatId, messageId: messageId, position: 0)
    try pinned.save(db)
    try markKnownMessagesPinned(db, chatId: chatId, messageIds: [messageId], pinned: true)
  }

  static func unpin(_ db: Database, chatId: Int64, messageId: Int64) throws {
    try filter(Columns.chatId == chatId)
      .filter(Columns.messageId == messageId)
      .deleteAll(db)

    try markKnownMessagesPinned(db, chatId: chatId, messageIds: [messageId], pinned: false)
  }

  private static func markKnownMessagesPinned(
    _ db: Database,
    chatId: Int64,
    messageIds: [Int64],
    pinned: Bool
  ) throws {
    var request = Message.filter(Message.Columns.chatId == chatId)

    if messageIds.isEmpty {
      request = request.filter(Message.Columns.pinned == true)
    } else {
      request = request.filter(messageIds.contains(Message.Columns.messageId))
    }

    try request.updateAll(db, [Message.Columns.pinned.set(to: pinned)])
  }
}
