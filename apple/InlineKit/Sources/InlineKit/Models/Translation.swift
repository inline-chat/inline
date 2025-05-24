import Foundation
import GRDB
import InlineProtocol
import Logger

public struct Translation: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord, TableRecord, Sendable,
  Equatable
{
  public var id: Int64?
  public var messageId: Int64
  public var chatId: Int64
  public var translation: String
  public var language: String
  public var date: Date

  public enum Columns {
    static let id = Column(CodingKeys.id)
    static let messageId = Column(CodingKeys.messageId)
    static let chatId = Column(CodingKeys.chatId)
    static let translation = Column(CodingKeys.translation)
    static let language = Column(CodingKeys.language)
    static let date = Column(CodingKeys.date)
  }

  public static let message = belongsTo(
    Message.self,
    using: ForeignKey(["chatId", "messageId"], to: ["chatId", "messageId"])
  )
  public var message: QueryInterfaceRequest<Message> {
    request(for: Translation.message)
  }

  public static let chat = belongsTo(Chat.self)
  public var chat: QueryInterfaceRequest<Chat> {
    request(for: Translation.chat)
  }

  public init(
    id: Int64? = nil,
    messageId: Int64,
    chatId: Int64,
    translation: String,
    language: String,
    date: Date
  ) {
    self.id = id
    self.messageId = messageId
    self.chatId = chatId
    self.translation = translation
    self.language = language
    self.date = date
  }

  public init(from: InlineProtocol.MessageTranslation, chatId: Int64) {
    self.init(
      messageId: from.messageID,
      chatId: chatId,
      translation: from.translation,
      language: from.language,
      date: Date(timeIntervalSince1970: TimeInterval(from.date))
    )
  }
}

// MARK: - DB Helpers

public extension Translation {
  static func save(
    _ db: Database,
    protocolTranslation: InlineProtocol.MessageTranslation,
    chatId: Int64,
    publishChanges: Bool = false
  ) throws -> Translation {
    let translation = Translation(from: protocolTranslation, chatId: chatId)
    try translation.save(db)
    return translation
  }

  static func getTranslations(
    _ db: Database,
    messageIds: [Int64],
    chatId: Int64,
    language: String
  ) throws -> [Translation] {
    try Translation
      .filter(messageIds.contains(Column("messageId")))
      .filter(Column("chatId") == chatId)
      .filter(Column("language") == language)
      .fetchAll(db)
  }
}
