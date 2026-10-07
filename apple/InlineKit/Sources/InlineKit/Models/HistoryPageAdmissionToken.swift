import Foundation
import GRDB
import InlineProtocol

/// Captured before a request; the upper bound prevents a snapshot's absence
/// proof from deleting messages first learned after it was dispatched.
public struct HistoryPageAdmissionToken: Codable, Sendable, Equatable {
  public var chatId: Int64
  public var revision: Int64
  public var knownMaxMessageId: Int64
  public var removalRevision: Int64

  public init(chatId: Int64, revision: Int64, knownMaxMessageId: Int64, removalRevision: Int64 = 0) {
    self.chatId = chatId
    self.revision = revision
    self.knownMaxMessageId = knownMaxMessageId
    self.removalRevision = removalRevision
  }

  public static func capture(_ db: Database, chatId: Int64) throws -> Self {
    guard let revision = try Int64.fetchOne(
      db, sql: "SELECT historyAdmissionRevision FROM chat WHERE id = ?", arguments: [chatId]
    ) else { throw HistoryPageAdmissionError.missingChat }
    let maximum = try Int64.fetchOne(
      db,
      sql: "SELECT MAX(messageId) FROM message WHERE chatId = ? AND messageId BETWEEN 1 AND ?",
      arguments: [chatId, MessageHistoryHole.positiveMessageIDMax]
    ) ?? 0
    return try Self(
      chatId: chatId,
      revision: revision,
      knownMaxMessageId: maximum,
      removalRevision: SyncRemovalRevision.read(db)
    )
  }

  public static func resolveChatId(_ db: Database, peer: Peer) throws -> Int64 {
    switch peer {
      case let .thread(id):
        guard try Chat.fetchOne(db, id: id) != nil else { throw HistoryPageAdmissionError.missingChat }
        return id
      case let .user(id):
        guard let chat = try Chat.filter(Chat.Columns.peerUserId == id).fetchOne(db)
        else { throw HistoryPageAdmissionError.missingChat }
        return chat.id
    }
  }

  public static func capture(_ db: Database, peer: Peer) throws -> Self {
    try capture(db, chatId: resolveChatId(db, peer: peer))
  }

  static func canonicalPeer(_ db: Database, peer: Peer) throws -> Peer {
    try Chat.getByPeerId(db: db, peerId: peer)?.deepLinkPeer ?? peer
  }

  public func validateSnapshot(_ db: Database, peer: Peer, seq: Int64?) throws {
    try validate(db, chatId: Self.resolveChatId(db, peer: peer))
    guard let seq else { throw HistoryPageAdmissionError.unavailable }
    guard seq >= 0 else { throw HistoryPageAdmissionError.malformedPage }
    let entityId: Int64 = switch peer {
      case let .thread(id): -id
      case let .user(id): id
    }
    let committed = try Int64.fetchOne(
      db, sql: "SELECT seq FROM sync_bucket_state WHERE bucketType = 1 AND entityId = ?", arguments: [entityId]
    ) ?? 0
    guard committed >= seq else { throw HistoryPageAdmissionError.stale }
  }

  public func validate(_ db: Database, chatId: Int64) throws {
    guard self.chatId == chatId,
          try SyncRemovalRevision.read(db) == removalRevision,
          try Int64
          .fetchOne(db, sql: "SELECT historyAdmissionRevision FROM chat WHERE id = ?", arguments: [chatId]) == revision
    else { throw HistoryPageAdmissionError.stale }
  }

  public static func advanceRevision(_ db: Database, chatId: Int64) throws {
    try db.execute(
      sql: "UPDATE chat SET historyAdmissionRevision = historyAdmissionRevision + 1 WHERE id = ?",
      arguments: [chatId]
    )
    if db.changesCount == 0 {
      // A cold catalog response has no per-chat revision to compare. Fence its
      // dispatch snapshot through the existing removal marker instead.
      try SyncRemovalRevision.advance(db)
    }
  }
}

public enum HistoryPageAdmissionError: Error, Sendable {
  case missingChat, stale, unavailable, malformedPage
}

extension Peer {
  func toHistoryProtocolPeer() -> InlineProtocol.Peer {
    .with { value in
      switch self {
        case let .thread(id): value.chat = .with { $0.chatID = id }
        case let .user(id): value.user = .with { $0.userID = id }
      }
    }
  }
}
