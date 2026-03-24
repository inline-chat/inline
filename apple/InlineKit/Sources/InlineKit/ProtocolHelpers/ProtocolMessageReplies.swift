import Foundation
import GRDB
import InlineProtocol
import Logger

extension InlineProtocol.MessageReplies: Codable {
  private enum CodingKeys: String, CodingKey {
    case chatID
    case replyCount
    case hasUnread_p
    case recentReplierUserIds
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    chatID = try container.decode(Int64.self, forKey: .chatID)
    replyCount = try container.decode(Int32.self, forKey: .replyCount)
    hasUnread_p = try container.decode(Bool.self, forKey: .hasUnread_p)
    recentReplierUserIds = try container.decodeIfPresent([Int64].self, forKey: .recentReplierUserIds) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(chatID, forKey: .chatID)
    try container.encode(replyCount, forKey: .replyCount)
    try container.encode(hasUnread_p, forKey: .hasUnread_p)
    try container.encode(recentReplierUserIds, forKey: .recentReplierUserIds)
  }
}

extension InlineProtocol.MessageReplies: DatabaseValueConvertible {
  public var databaseValue: DatabaseValue {
    do {
      let data = try serializedData()
      return data.databaseValue
    } catch {
      Log.shared.error("Failed to serialize MessageReplies to database", error: error)
      return DatabaseValue.null
    }
  }

  public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> MessageReplies? {
    guard let data = Data.fromDatabaseValue(dbValue) else {
      return nil
    }

    do {
      return try MessageReplies(serializedBytes: data)
    } catch {
      Log.shared.error("Failed to deserialize MessageReplies from database", error: error)
      return nil
    }
  }
}
