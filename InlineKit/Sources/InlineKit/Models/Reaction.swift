import Foundation
import GRDB

public struct ApiReaction: Codable, Sendable {
  public var id: Int64
  public var messageId: Int64
  public var userId: Int64
  public var chatId: Int64
  public var emoji: String
  public var date: Int
}

public struct Reaction: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
  TableRecord,
  Sendable, Equatable
{
  public var id: Int64
  public var messageId: Int64
  public var userId: Int64
  public var chatId: Int64
  public var emoji: String
  public var date: Date

  public static let message = belongsTo(Message.self)
  public var message: QueryInterfaceRequest<Message> {
    request(for: Reaction.message)
  }

  enum CodingKeys: String, CodingKey {
    case id
    case messageId
    case userId
    case emoji
    case date
    case chatId
  }

  public init(id: Int64, messageId: Int64, userId: Int64, emoji: String, date: Date, chatId: Int64) {
    self.id = id
    self.messageId = messageId
    self.userId = userId
    self.emoji = emoji
    self.date = date
    self.chatId = chatId
  }
}

public extension Reaction {
  init(from: ApiReaction) {
    self.id = from.id
    self.messageId = from.messageId
    self.userId = from.userId
    self.chatId = from.chatId
    self.emoji = from.emoji
    self.date = Self.fromTimestamp(from: from.date)
  }
}

public extension Reaction {
  static func fromTimestamp(from: Int) -> Date {
    return Date(timeIntervalSince1970: Double(from) / 1000)
  }
}
