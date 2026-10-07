import GRDB

/// An inclusive numeric message-ID interval whose history is not yet certified.
public struct MessageHistoryHole: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
  public static let databaseTableName = "messageHistoryHole"
  public static let positiveMessageIDMax = Int64(Int32.max)

  public var chatId: Int64
  public var scope: Int
  public var lowerId: Int64
  public var upperId: Int64

  public init(chatId: Int64, scope: MessageHistoryScope = .timeline, lowerId: Int64, upperId: Int64) {
    self.chatId = chatId
    self.scope = scope.rawValue
    self.lowerId = lowerId
    self.upperId = upperId
  }

  public enum Columns {
    public static let chatId = Column(CodingKeys.chatId)
    public static let scope = Column(CodingKeys.scope)
    public static let lowerId = Column(CodingKeys.lowerId)
    public static let upperId = Column(CodingKeys.upperId)
  }
}

/// Transaction-scoped interval operations. Message rows never imply coverage.
public enum MessageHistoryCoverageStore {
  public static func holes(
    _ db: Database,
    chatId: Int64,
    scope: MessageHistoryScope = .timeline
  ) throws -> [MessageHistoryHole] {
    try MessageHistoryHole
      .filter(MessageHistoryHole.Columns.chatId == chatId && MessageHistoryHole.Columns.scope == scope.rawValue)
      .order(MessageHistoryHole.Columns.lowerId)
      .fetchAll(db)
  }

  public static func invalidate(_ db: Database, chatId: Int64, scope: MessageHistoryScope = .timeline) throws {
    try MessageHistoryHole
      .filter(MessageHistoryHole.Columns.chatId == chatId && MessageHistoryHole.Columns.scope == scope.rawValue)
      .deleteAll(db)
    try MessageHistoryHole(
      chatId: chatId,
      scope: scope,
      lowerId: 1,
      upperId: MessageHistoryHole.positiveMessageIDMax
    ).insert(db)
  }

  public static func intersects(
    _ db: Database,
    chatId: Int64,
    scope: MessageHistoryScope = .timeline,
    lowerId: Int64,
    upperId: Int64
  ) throws -> Bool {
    let lower = max(1, lowerId)
    let upper = min(MessageHistoryHole.positiveMessageIDMax, upperId)
    guard lower <= upper else { return false }
    return try MessageHistoryHole
      .filter(
        MessageHistoryHole.Columns.chatId == chatId &&
          MessageHistoryHole.Columns.scope == scope.rawValue &&
          MessageHistoryHole.Columns.lowerId <= upper &&
          MessageHistoryHole.Columns.upperId >= lower
      )
      .fetchCount(db) > 0
  }

  public static func subtract(
    _ db: Database,
    chatId: Int64,
    scope: MessageHistoryScope = .timeline,
    lowerId: Int64,
    upperId: Int64
  ) throws {
    let lower = max(1, lowerId)
    let upper = min(MessageHistoryHole.positiveMessageIDMax, upperId)
    guard lower <= upper else { return }

    let existing = try normalized(holes(db, chatId: chatId, scope: scope), chatId: chatId, scope: scope)
    guard !existing.isEmpty else { return }

    var remaining: [MessageHistoryHole] = []
    remaining.reserveCapacity(existing.count + 1)
    for hole in existing {
      if upper < hole.lowerId || lower > hole.upperId {
        remaining.append(hole)
        continue
      }
      if hole.lowerId < lower {
        remaining.append(MessageHistoryHole(
          chatId: chatId,
          scope: scope,
          lowerId: hole.lowerId,
          upperId: lower - 1
        ))
      }
      if hole.upperId > upper, upper < MessageHistoryHole.positiveMessageIDMax {
        remaining.append(MessageHistoryHole(
          chatId: chatId,
          scope: scope,
          lowerId: upper + 1,
          upperId: hole.upperId
        ))
      }
    }

    try MessageHistoryHole
      .filter(MessageHistoryHole.Columns.chatId == chatId && MessageHistoryHole.Columns.scope == scope.rawValue)
      .deleteAll(db)
    for hole in remaining {
      try hole.insert(db)
    }
  }

  public static func invalidateAll(_ db: Database, chatId: Int64) throws {
    for scope in MessageHistoryScope.allCases {
      try invalidate(db, chatId: chatId, scope: scope)
    }
    try HistoryPageAdmissionToken.advanceRevision(db, chatId: chatId)
  }

  /// Complete ordinary pages also prove every fixed resource predicate.
  public static func subtractAll(_ db: Database, chatId: Int64, lowerId: Int64, upperId: Int64) throws {
    for scope in MessageHistoryScope.allCases {
      try subtract(db, chatId: chatId, scope: scope, lowerId: lowerId, upperId: upperId)
    }
  }

  private static func normalized(
    _ holes: [MessageHistoryHole],
    chatId: Int64,
    scope: MessageHistoryScope
  ) -> [MessageHistoryHole] {
    var result: [MessageHistoryHole] = []
    for hole in holes.sorted(by: { $0.lowerId < $1.lowerId }) {
      let lower = max(1, hole.lowerId)
      let upper = min(MessageHistoryHole.positiveMessageIDMax, hole.upperId)
      guard lower <= upper else { continue }
      guard let last = result.last else {
        result.append(MessageHistoryHole(chatId: chatId, scope: scope, lowerId: lower, upperId: upper))
        continue
      }
      let adjacent = last.upperId < MessageHistoryHole.positiveMessageIDMax && lower == last.upperId + 1
      if lower <= last.upperId || adjacent {
        result[result.count - 1].upperId = max(last.upperId, upper)
      } else {
        result.append(MessageHistoryHole(chatId: chatId, scope: scope, lowerId: lower, upperId: upper))
      }
    }
    return result
  }
}
