import Foundation
import GRDB
import InlineProtocol

/// Who a bot acts for (today its creator), as the server reports in `botInfo`.
/// Kept apart from `User` so user saves that carry no owner never erase it.
/// Lets mention menus offer the current user's own bots before any chat exists.
public struct BotOwner: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
  public static let databaseTableName = "botOwner"

  public var botUserId: Int64
  public var ownerUserId: Int64

  public enum Columns {
    static let botUserId = Column(CodingKeys.botUserId)
    static let ownerUserId = Column(CodingKeys.ownerUserId)
  }

  public init(botUserId: Int64, ownerUserId: Int64) {
    self.botUserId = botUserId
    self.ownerUserId = ownerUserId
  }

  static func ownerUserId(from user: InlineProtocol.User) -> Int64? {
    guard user.hasBotInfo, case let .ownerUserID(ownerUserId)? = user.botInfo.owner, ownerUserId > 0 else {
      return nil
    }
    return ownerUserId
  }

  /// Writes only on change, so repeated saves don't wake observers.
  static func set(_ db: Database, botUserId: Int64, ownerUserId: Int64) throws {
    if let existing = try BotOwner.fetchOne(db, key: botUserId), existing.ownerUserId == ownerUserId {
      return
    }
    try BotOwner(botUserId: botUserId, ownerUserId: ownerUserId).save(db)
  }

  static func remove(_ db: Database, botUserId: Int64) throws {
    _ = try BotOwner.deleteOne(db, key: botUserId)
  }

  /// `botUserIds` is everything `ownerUserId` owns: any other bot stops being theirs.
  static func replaceOwnedBots(_ db: Database, botUserIds: [Int64], ownerUserId: Int64) throws {
    for botUserId in botUserIds {
      try set(db, botUserId: botUserId, ownerUserId: ownerUserId)
    }
    try BotOwner
      .filter(Columns.ownerUserId == ownerUserId)
      .filter(!botUserIds.contains(Columns.botUserId))
      .deleteAll(db)
  }

  /// The live bots `ownerUserId` owns.
  static func ownedBotIds(_ db: Database, ownerUserId: Int64) throws -> Set<Int64> {
    try Set(Int64.fetchAll(
      db,
      sql: """
      SELECT botOwner.botUserId FROM botOwner
      JOIN user ON user.id = botOwner.botUserId
      WHERE botOwner.ownerUserId = ? AND user.bot = 1
      """,
      arguments: [ownerUserId]
    ))
  }
}
