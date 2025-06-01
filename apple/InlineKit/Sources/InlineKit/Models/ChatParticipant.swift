import Foundation
import GRDB
import InlineProtocol
import Logger

public struct ChatParticipant: Codable, FetchableRecord, PersistableRecord {
  public var id: Int64?
  public var chatId: Int64
  public var userId: Int64
  public var date: Date

  public enum Columns {
    public static let id = Column(CodingKeys.id)
    public static let chatId = Column(CodingKeys.chatId)
    public static let userId = Column(CodingKeys.userId)
    public static let date = Column(CodingKeys.date)
  }

  static let chat = belongsTo(Chat.self)
  public var chat: QueryInterfaceRequest<Chat> {
    request(for: ChatParticipant.chat)
  }

  static let user = belongsTo(User.self)
  public var user: QueryInterfaceRequest<User> {
    request(for: ChatParticipant.user)
  }

  public init(chatId: Int64, userId: Int64, date: Date) {
    self.chatId = chatId
    self.userId = userId
    self.date = date
  }
}

public extension ChatParticipant {
  init(from: InlineProtocol.ChatParticipant, chatId: Int64) {
    self.chatId = chatId
    userId = from.userID
    date = Date(timeIntervalSince1970: TimeInterval(from.date))
  }

  static func save(_ db: Database, from: InlineProtocol.ChatParticipant, chatId: Int64) {
    do {
      let existingParticipant = try ChatParticipant
        .filter(Column("chatId") == chatId)
        .filter(Column("userId") == from.userID)
        .fetchOne(db)

      var participant: ChatParticipant

      if let existingId = existingParticipant?.id {
        participant = ChatParticipant(from: from, chatId: chatId)
        participant.id = existingId // reuse existing ID
      } else {
        participant = ChatParticipant(from: from, chatId: chatId)
      }

      try participant.save(db, onConflict: .replace) // replace bc previous we used random IDs
    } catch {
      Log.shared.error("Error saving chat participant:", error: error)
    }
  }
}
