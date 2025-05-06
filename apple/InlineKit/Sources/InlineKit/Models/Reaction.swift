import Foundation
import GRDB
import InlineProtocol

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
  public var id: Int64?
  public var messageId: Int64
  public var userId: Int64
  public var chatId: Int64
  public var emoji: String
  public var date: Date

  public static let message = belongsTo(
    Message.self,
    using: ForeignKey(["chatId", "messageId"], to: ["chatId", "messageId"])
  )
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

  public init(
    id: Int64 = Int64.random(in: 1 ... 50_000),
    messageId: Int64,
    userId: Int64,
    emoji: String,
    date: Date,
    chatId: Int64
  ) {
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
    id = from.id
    messageId = from.messageId
    userId = from.userId
    chatId = from.chatId
    emoji = from.emoji
    date = Self.fromTimestamp(from: from.date)
  }
}

public extension Reaction {
  static func fromTimestamp(from: Int) -> Date {
    Date(timeIntervalSince1970: Double(from) / 1_000)
  }
}

public extension Reaction {
  init(from: InlineProtocol.Reaction) {
    messageId = from.messageID
    userId = from.userID
    chatId = from.chatID
    emoji = from.emoji
    // Handle both milliseconds (old format) and seconds (new format)
    // If the timestamp is large (> 10^12), it's likely in milliseconds
    date = from.date > 1_000_000_000_000
      ? Date(timeIntervalSince1970: TimeInterval(from.date) / 1_000)
      : Date(timeIntervalSince1970: TimeInterval(from.date))
  }

  static func save(
    _ db: Database, protocolMessage: InlineProtocol.Reaction, publishChanges: Bool = false
  ) throws -> Reaction {
    let reaction = Reaction(from: protocolMessage)
    try reaction.save(db)
    return reaction
  }
}
