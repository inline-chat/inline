import Foundation
import GRDB

public enum ChatType: String, Codable, Sendable {
  case privateChat = "private"
  case thread
}

public struct ApiChat: Codable, Hashable, Sendable {
  public var id: Int64
  public var date: Int
  public var title: String?
  public var type: String
  public var spaceId: Int64?
  public var threadNumber: Int?
  public var peer: Peer?
  public var lastMsgId: Int64?
  public var emoji: String?
}

public struct Chat: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord, Sendable {
  public var id: Int64
  public var date: Date
  public var type: ChatType
  public var title: String?
  public var spaceId: Int64?
  public var peerUserId: Int64?
  public var lastMsgId: Int64?
  public var emoji: String?

  public static let space = belongsTo(Space.self)
  public var space: QueryInterfaceRequest<Space> {
    request(for: Chat.space)
  }

  public static let lastMessage = hasOne(
    Message.self,
    using: ForeignKey(["chatId", "messageId"], to: ["id", "lastMsgId"])
  )

  public var lastMessage: QueryInterfaceRequest<Message> {
    request(for: Chat.lastMessage)
  }

  public static let messages = hasMany(
    Message.self
  )

  public var messages: QueryInterfaceRequest<Message> {
    request(for: Chat.messages)
  }

  public static let peerUser = belongsTo(User.self)

  public var peerUser: QueryInterfaceRequest<User> {
    request(for: Chat.peerUser)
  }

  public init(
    id: Int64 = Int64.random(in: 1 ... 50_000), date: Date, type: ChatType, title: String?,
    spaceId: Int64?, peerUserId: Int64? = nil, lastMsgId: Int64? = nil, emoji: String? = nil
  ) {
    self.id = id
    self.date = date
    self.type = type
    self.title = title
    self.spaceId = spaceId
    self.peerUserId = peerUserId
    self.lastMsgId = lastMsgId
    self.emoji = emoji
  }
}

public extension Chat {
  enum CodingKeys: String, CodingKey {
    case id
    case date
    case type
    case title
    case spaceId
    case peerUserId
    case lastMsgId
    case emoji
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(Int64.self, forKey: .id)
    date = try container.decode(Date.self, forKey: .date)
    type = try container.decode(ChatType.self, forKey: .type)
    title = try container.decodeIfPresent(String.self, forKey: .title)
    spaceId = try container.decodeIfPresent(Int64.self, forKey: .spaceId)
    peerUserId = try container.decodeIfPresent(Int64.self, forKey: .peerUserId)
    lastMsgId = try container.decodeIfPresent(Int64.self, forKey: .lastMsgId)
    emoji = try container.decodeIfPresent(String.self, forKey: .emoji)
  }
}

public extension Chat {
  init(from: ApiChat) {
    id = from.id
    date = Self.fromTimestamp(from: from.date)
    title = from.title
    spaceId = from.spaceId
    type = from.type == "private" ? .privateChat : .thread
    peerUserId =
      if let peer = from.peer
    {
      switch peer {
        case let .user(id):
          id
        case .thread:
          nil
      }
    } else {
      nil
    }
    lastMsgId = from.lastMsgId
    emoji = from.emoji
  }

  static func fromTimestamp(from: Int) -> Date {
    Date(timeIntervalSince1970: Double(from))
  }
}

public extension Chat {
  static func getByPeerId(peerId: Peer) throws -> Chat? {
    try AppDatabase.shared.reader.read { db in
      switch peerId {
        case let .user(id):
          // Fetch private chat
          try Chat
            .filter(Column("peerUserId") == id)
            .fetchOne(db)

        case let .thread(id):
          // Fetch thread chat
          try Chat.filter(Column("id") == id).fetchOne(db)
      }
    }
  }
}
