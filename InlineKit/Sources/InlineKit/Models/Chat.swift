import Foundation
import GRDB

public enum ChatType: String, Codable {
  case privateChat = "private"
  case thread
}

public struct Chat: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord, @unchecked Sendable {
  public var id: Int64
  public var date: Date
  public var type: ChatType
  public var title: String?
  public var spaceId: Int64?
  public var minUserId: Int64?
  public var maxUserId: Int64?

  public nonisolated(unsafe) static let space = belongsTo(Space.self)
  public var space: QueryInterfaceRequest<Space> {
    request(for: Chat.space)
  }

  public nonisolated(unsafe) static let minUser = belongsTo(User.self)
  public var minUser: QueryInterfaceRequest<User> {
    request(for: Chat.minUser)
  }

  public nonisolated(unsafe) static let maxUser = belongsTo(User.self)
  public var maxUser: QueryInterfaceRequest<User> {
    request(for: Chat.maxUser)
  }

  public nonisolated(unsafe) static let messages = hasMany(Message.self)
  public var messages: QueryInterfaceRequest<Message> {
    request(for: Chat.messages)
  }
}

public extension Chat {
  enum CodingKeys: String, CodingKey {
    case id
    case date
    case type
    case title
    case spaceId
    case minUserId
    case maxUserId
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(Int64.self, forKey: .id)
    date = try container.decode(Date.self, forKey: .date)
    type = try container.decode(ChatType.self, forKey: .type)
    title = try container.decodeIfPresent(String.self, forKey: .title)
    spaceId = try container.decodeIfPresent(Int64.self, forKey: .spaceId)
    minUserId = try container.decodeIfPresent(Int64.self, forKey: .minUserId)
    maxUserId = try container.decodeIfPresent(Int64.self, forKey: .maxUserId)
  }
}
