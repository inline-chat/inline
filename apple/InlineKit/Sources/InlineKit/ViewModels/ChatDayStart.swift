import Foundation
import GRDB

/// Where a day starts in a chat: its first message, proven by history coverage. A day pill's click (both platforms)
/// jumps there; the list then loads a window around it as a jump to any message does.
public enum ChatDayStart {
  /// Older pages fetched at most to reach a day's start across history holes (100 messages each).
  static let maximumPages = 8

  /// The id of the first message dated in `[dayStart, dayEnd)`: the first cached one when no hole lies between it and
  /// the message before it; otherwise older history is fetched from the server (a page at a time, as paging does) and
  /// looked at again. Nil when the day has no cached message. Offline or past the page budget it answers with the
  /// earliest message known.
  @MainActor
  public static func firstMessageId(
    peer: Peer,
    dayStart: Date,
    dayEnd: Date,
    database: AppDatabase = .shared
  ) async throws -> Int64? {
    var known: Int64?
    for _ in 0 ... maximumPages {
      let found = try await database.reader.read { db in
        try earliestCached(db, peer: peer, dayStart: dayStart, dayEnd: dayEnd)
      }
      guard let found else { return known }
      known = found.messageId
      guard found.holeBefore else { return found.messageId }
      do {
        let outcome = try await MessageHistoryRepairCoordinator.shared.loadOlder(peer: peer, beforeID: found.messageId)
        if outcome != .loaded { return found.messageId }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Offline or failed: the earliest message known is the best start there is.
        return found.messageId
      }
    }
    return known
  }

  /// The day's first cached message and whether unknown history lies just before it.
  nonisolated static func earliestCached(
    _ db: Database, peer: Peer, dayStart: Date, dayEnd: Date
  ) throws -> (messageId: Int64, holeBefore: Bool)? {
    guard let chatId = try chatId(for: peer, db: db) else { return nil }
    let messages = Message.filter(Column("chatId") == chatId && Column("messageId") > 0)
    guard let first = try messages
      .filter(Column("date") >= dayStart && Column("date") < dayEnd)
      .order(Column("messageId").asc)
      .fetchOne(db)
    else { return nil }
    let previous = try messages
      .filter(Column("messageId") < first.messageId)
      .order(Column("messageId").desc)
      .fetchOne(db)
    let hole = try MessageHistoryCoverageStore.intersects(
      db, chatId: chatId, lowerId: (previous?.messageId ?? 0) + 1, upperId: first.messageId - 1
    )
    return (first.messageId, hole)
  }

  private nonisolated static func chatId(for peer: Peer, db: Database) throws -> Int64? {
    switch peer {
      case let .thread(chatId): chatId
      case let .user(userId): try Chat.filter(Chat.Columns.peerUserId == userId).fetchOne(db)?.id
    }
  }
}
