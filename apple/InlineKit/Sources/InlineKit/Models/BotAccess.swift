import Foundation
import GRDB
import InlineProtocol

/// Whether the current user can reach a bot, as the server last resolved it:
/// the owner, anyone on the bot's access list (directly, or through a space or
/// group), or anyone when the bot is open to everyone.
///
/// Stored so the first frame is right without a network call: a bot the user
/// can't reach has no composer, and isn't offered in mention menus or search.
/// A missing row means "not asked yet", which is neither answer.
public struct BotAccess: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
  public static let databaseTableName = "botAccess"

  public var botUserId: Int64
  public var canMessage: Bool
  /// The bot wrote to the user in their DM recently, so they can answer it
  /// there without access. Keeps the composer; offers the bot nowhere.
  public var canReply: Bool
  /// One bit per `AgentGrantOperation` raw value, from the access list.
  public var operations: Int64

  public enum Columns {
    static let botUserId = Column(CodingKeys.botUserId)
    static let canMessage = Column(CodingKeys.canMessage)
    static let canReply = Column(CodingKeys.canReply)
    static let operations = Column(CodingKeys.operations)
  }

  public init(
    botUserId: Int64,
    canMessage: Bool,
    canReply: Bool = false,
    operations: Set<InlineProtocol.AgentGrantOperation>
  ) {
    self.botUserId = botUserId
    self.canMessage = canMessage
    self.canReply = canReply
    self.operations = Self.mask(operations)
  }

  public init(_ access: InlineProtocol.AgentAccess) {
    self.init(
      botUserId: access.botUserID,
      canMessage: access.canMessage,
      canReply: access.canReply,
      operations: Set(access.operations)
    )
  }

  public var grantOperations: Set<InlineProtocol.AgentGrantOperation> {
    Self.operations(mask: operations)
  }

  static func mask(_ operations: Set<InlineProtocol.AgentGrantOperation>) -> Int64 {
    operations.reduce(Int64(0)) { mask, operation in
      let bit = operation.rawValue
      return bit > 0 && bit < 63 ? mask | (Int64(1) << Int64(bit)) : mask
    }
  }

  static func operations(mask: Int64) -> Set<InlineProtocol.AgentGrantOperation> {
    Set(InlineProtocol.AgentGrantOperation.allCases.filter { operation in
      let bit = operation.rawValue
      return bit > 0 && bit < 63 && mask & (Int64(1) << Int64(bit)) != 0
    })
  }

  /// Writes only on change, so repeated answers don't wake observers.
  @discardableResult
  static func set(_ db: Database, _ access: BotAccess) throws -> Bool {
    if try BotAccess.fetchOne(db, key: access.botUserId) == access { return false }
    try access.save(db)
    return true
  }
}

/// Which locally known bots to leave out of a list for one viewer.
public struct BotVisibility: Equatable, Sendable {
  /// Bots the viewer isn't known to reach: not theirs, and either unreachable
  /// or not asked about yet. Left out wherever a bot is offered to be used
  /// (mention menus, search, pickers), so nothing shows up by default.
  public var notOffered: Set<Int64>
  /// Bots the server said the viewer can't reach, and that haven't written
  /// to them lately. Only these lose their composer and their place among
  /// existing chats, so a bot never looks unreachable just because the
  /// answer hasn't arrived.
  public var unreachable: Set<Int64>

  public static let none = BotVisibility(notOffered: [], unreachable: [])

  public init(notOffered: Set<Int64>, unreachable: Set<Int64>) {
    self.notOffered = notOffered
    self.unreachable = unreachable
  }

  /// A bot's own owner always reaches it, whatever was stored before they
  /// created it or it was listed.
  ///
  /// Until the server has answered about at least one bot, nothing is left
  /// out: a server that predates access answers, or a first launch offline,
  /// must not empty the mention menu of bots people use every day.
  public static func fetch(_ db: Database, viewerUserId: Int64?) throws -> BotVisibility {
    guard try BotAccess.fetchCount(db) > 0 else { return .none }
    let rows = try Row.fetchAll(
      db,
      sql: """
      SELECT user.id AS id, botAccess.canMessage AS canMessage, botAccess.canReply AS canReply
      FROM user
      LEFT JOIN botOwner ON botOwner.botUserId = user.id
      LEFT JOIN botAccess ON botAccess.botUserId = user.id
      WHERE user.bot = 1
        AND COALESCE(botOwner.ownerUserId, 0) != ?
        AND COALESCE(botAccess.canMessage, 0) = 0
      """,
      arguments: [viewerUserId ?? 0]
    )
    var visibility = BotVisibility.none
    for row in rows {
      let id: Int64 = row["id"]
      visibility.notOffered.insert(id)
      let canMessage: Bool? = row["canMessage"]
      let canReply: Bool? = row["canReply"]
      if canMessage == false, canReply != true { visibility.unreachable.insert(id) }
    }
    return visibility
  }

  /// Bots saved locally that the server hasn't been asked about.
  static func unaskedBotIds(_ db: Database) throws -> [Int64] {
    try Int64.fetchAll(
      db,
      sql: """
      SELECT user.id FROM user
      LEFT JOIN botAccess ON botAccess.botUserId = user.id
      WHERE user.bot = 1 AND botAccess.botUserId IS NULL
      ORDER BY user.id
      """
    )
  }

  static func allBotIds(_ db: Database) throws -> [Int64] {
    try Int64.fetchAll(db, sql: "SELECT id FROM user WHERE bot = 1 ORDER BY id")
  }
}
