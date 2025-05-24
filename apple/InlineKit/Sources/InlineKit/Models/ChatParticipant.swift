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
    static let id = Column(CodingKeys.id)
    static let chatId = Column(CodingKeys.chatId)
    static let userId = Column(CodingKeys.userId)
    static let date = Column(CodingKeys.date)
  }

  static let chat = belongsTo(Chat.self)
  public var chat: QueryInterfaceRequest<Chat> {
    request(for: ChatParticipant.chat)
  }

  static let user = belongsTo(User.self)
  public var user: QueryInterfaceRequest<User> {
    request(for: ChatParticipant.user)
  }

  public init(id: Int64? = Int64.random(in: 1 ... 50_000), chatId: Int64, userId: Int64, date: Date) {
    self.id = id
    self.chatId = chatId
    self.userId = userId
    self.date = date
  }
}

public extension ChatParticipant {
  init(from: InlineProtocol.ChatParticipant, chatId: Int64, id: Int64) {
    self.chatId = chatId
    userId = from.userID
    date = Date(timeIntervalSince1970: TimeInterval(from.date))
  }

  static func save(_ db: Database, from: InlineProtocol.ChatParticipant, chatId: Int64) {
    do {
      let existingParticipant = try ChatParticipant
        .filter(Column("chatId") == chatId && Column("userId") == from.userID)
        .fetchOne(db)

      let participant = if let existing = existingParticipant {
        ChatParticipant(from: from, chatId: chatId, id: existing.id ?? Int64.random(in: 1 ... 50_000))
      } else {
        ChatParticipant(from: from, chatId: chatId, id: Int64.random(in: 1 ... 50_000))
      }

      try participant.save(db)
    } catch {
      Log.shared.error("Error saving chat participant:", error: error)
    }
  }
}
