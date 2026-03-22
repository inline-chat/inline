import Foundation
import GRDB

public struct ReservedChatID: FetchableRecord, PersistableRecord, TableRecord, Sendable, Codable, Hashable {
  public static let databaseTableName = "reservedChatId"

  public var chatId: Int64
  public var expiresAt: Date
  public var createdAt: Date

  public enum Columns {
    public static let chatId = Column(CodingKeys.chatId)
    public static let expiresAt = Column(CodingKeys.expiresAt)
    public static let createdAt = Column(CodingKeys.createdAt)
  }

  public init(chatId: Int64, expiresAt: Date, createdAt: Date = .now) {
    self.chatId = chatId
    self.expiresAt = expiresAt
    self.createdAt = createdAt
  }
}
