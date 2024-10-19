import Foundation
import GRDB

public struct Message: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord, @unchecked Sendable {
  public var id: Int64
  public var date: Date
  public var text: String?
  public var chatId: Int64
  public var fromId: Int64
  public var editDate: Date?

  public nonisolated(unsafe) static let chat = belongsTo(Chat.self)
  public var chat: QueryInterfaceRequest<Chat> {
    request(for: Message.chat)
  }

  public nonisolated(unsafe) static let from = belongsTo(User.self)
  public var from: QueryInterfaceRequest<User> {
    request(for: Message.from)
  }

  public init(id: Int64 = Int64.random(in: 1 ... 5000), date: Date, text: String?, chatId: Int64, fromId: Int64, editDate: Date?) {
    self.id = id
    self.date = date
    self.text = text
    self.chatId = chatId
    self.fromId = fromId
    self.editDate = editDate
  }
}

public extension Message {
  enum CodingKeys: String, CodingKey {
    case id
    case date
    case text
    case chatId
    case fromId
    case editDate
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(Int64.self, forKey: .id)
    date = try container.decode(Date.self, forKey: .date)
    text = try container.decodeIfPresent(String.self, forKey: .text)
    chatId = try container.decode(Int64.self, forKey: .chatId)
    fromId = try container.decode(Int64.self, forKey: .fromId)
    editDate = try container.decodeIfPresent(Date.self, forKey: .editDate)
  }
}
