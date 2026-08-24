import GRDB

/// An inclusive numeric message-ID interval whose history is not yet certified.
public struct MessageHistoryHole: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
  public static let databaseTableName = "messageHistoryHole"
  public static let positiveMessageIDMax = Int64.max - 1

  public var chatId: Int64
  public var lowerId: Int64
  public var upperId: Int64

  public init(chatId: Int64, lowerId: Int64, upperId: Int64) {
    self.chatId = chatId
    self.lowerId = lowerId
    self.upperId = upperId
  }

  public enum Columns {
    public static let chatId = Column(CodingKeys.chatId)
    public static let lowerId = Column(CodingKeys.lowerId)
    public static let upperId = Column(CodingKeys.upperId)
  }
}

/// Transaction-scoped interval operations. Message rows never imply coverage.
public enum MessageHistoryCoverageStore {
  public static func holes(_ db: Database, chatId: Int64) throws -> [MessageHistoryHole] {
    try MessageHistoryHole
      .filter(MessageHistoryHole.Columns.chatId == chatId)
      .order(MessageHistoryHole.Columns.lowerId)
      .fetchAll(db)
  }

  public static func invalidate(_ db: Database, chatId: Int64) throws {
    try MessageHistoryHole
      .filter(MessageHistoryHole.Columns.chatId == chatId)
      .deleteAll(db)
    try MessageHistoryHole(
      chatId: chatId,
      lowerId: 1,
      upperId: MessageHistoryHole.positiveMessageIDMax
    ).insert(db)
  }

  public static func intersects(
    _ db: Database,
    chatId: Int64,
    lowerId: Int64,
    upperId: Int64
  ) throws -> Bool {
    let lower = max(1, lowerId)
    let upper = min(MessageHistoryHole.positiveMessageIDMax, upperId)
    guard lower <= upper else { return false }
    return try MessageHistoryHole
      .filter(
        MessageHistoryHole.Columns.chatId == chatId &&
          MessageHistoryHole.Columns.lowerId <= upper &&
          MessageHistoryHole.Columns.upperId >= lower
      )
      .fetchCount(db) > 0
  }

  public static func subtract(
    _ db: Database,
    chatId: Int64,
    lowerId: Int64,
    upperId: Int64
  ) throws {
    let lower = max(1, lowerId)
    let upper = min(MessageHistoryHole.positiveMessageIDMax, upperId)
    guard lower <= upper else { return }

    let existing = normalized(try holes(db, chatId: chatId), chatId: chatId)
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
          lowerId: hole.lowerId,
          upperId: lower - 1
        ))
      }
      if hole.upperId > upper, upper < MessageHistoryHole.positiveMessageIDMax {
        remaining.append(MessageHistoryHole(
          chatId: chatId,
          lowerId: upper + 1,
          upperId: hole.upperId
        ))
      }
    }

    try MessageHistoryHole
      .filter(MessageHistoryHole.Columns.chatId == chatId)
      .deleteAll(db)
    for hole in remaining {
      try hole.insert(db)
    }
  }

  private static func normalized(
    _ holes: [MessageHistoryHole],
    chatId: Int64
  ) -> [MessageHistoryHole] {
    var result: [MessageHistoryHole] = []
    for hole in holes.sorted(by: { $0.lowerId < $1.lowerId }) {
      let lower = max(1, hole.lowerId)
      let upper = min(MessageHistoryHole.positiveMessageIDMax, hole.upperId)
      guard lower <= upper else { continue }
      guard let last = result.last else {
        result.append(MessageHistoryHole(chatId: chatId, lowerId: lower, upperId: upper))
        continue
      }
      let adjacent = last.upperId < MessageHistoryHole.positiveMessageIDMax && lower == last.upperId + 1
      if lower <= last.upperId || adjacent {
        result[result.count - 1].upperId = max(last.upperId, upper)
      } else {
        result.append(MessageHistoryHole(chatId: chatId, lowerId: lower, upperId: upper))
      }
    }
    return result
  }
}
