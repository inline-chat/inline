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
