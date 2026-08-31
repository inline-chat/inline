import Foundation
import GRDB
import InlineProtocol
import RealtimeV2

/// Process-wide owner for on-demand history-hole repair. Views request a
/// coordinate; this owner decides whether durable coverage already proves it
/// and coalesces concurrent requests for the same chat.
@MainActor
public final class MessageHistoryRepairCoordinator {
  public static let shared = MessageHistoryRepairCoordinator()

  public enum Outcome: Sendable, Equatable {
    case notNeeded
    case empty
    case loaded
  }

  private enum RepairError: Error {
    case unresolvedChat
    case invalidResponse
  }

  private struct PageRequest: Hashable {
    let chatID: Int64
    let boundaryID: Int64
    let older: Bool
  }

  private var pageTasks: [PageRequest: Task<Outcome, Error>] = [:]

  private init() {}

  /// The caller owns cancellation and presentation. Unlike an exact-ID lookup,
  /// this prepares neighboring rows and records their history coverage together.
  public func loadAround(
    peer: Peer,
    anchorID: Int64,
    limit: Int,
    database: AppDatabase = .shared
  ) async throws -> Outcome {
    guard 1 ... MessageHistoryHole.positiveMessageIDMax ~= anchorID else {
      throw RepairError.invalidResponse
    }
    let windowLimit = Int32(clamping: max(60, limit))
    let cached = try await database.reader.read { db in
      let chat = try Chat.getByPeerId(db: db, peerId: peer)
      let window = try Self.aroundCache(db, chat: chat, anchorID: anchorID, limit: Int(windowLimit))
      return (
        hasChat: chat != nil,
        hasTarget: window.hasTarget,
        needsHistory: window.needsHistory
      )
    }
    try Task.checkCancellation()
    guard cached.needsHistory else { return .notNeeded }

    do {
      // A cold DM needs its canonical Chat before the history transaction can
      // persist messages. Use the normal chat transaction, not notification state.
      if !cached.hasChat {
        _ = try await Api.realtime.send(.getChat(peer: peer))
        try Task.checkCancellation()
      }
      var transaction = GetChatHistoryTransaction(
        peer: peer,
        mode: .historyModeAround,
        anchorID: anchorID,
        limit: windowLimit,
        includeAnchor: true
      )
      // Repairing context for an existing target is optional: do not queue that
      // refinement behind an offline connection and delay an otherwise usable jump.
      if cached.hasTarget { transaction.type = .ephemeral() }
      let rpcResult = try await Api.realtime.send(transaction)
      try Task.checkCancellation()
      guard let rpcResult, case let .getChatHistory(result) = rpcResult else {
        throw RepairError.invalidResponse
      }
      // AROUND is a coordinate query, not an exact-message lookup. The anchor
      // may have been deleted while the returned neighbors still establish a
      // useful and durably certified window around that coordinate.
      return result.messages.isEmpty ? .empty : .loaded
    } catch {
      try Task.checkCancellation()
      // Preserve offline jumps to an exact cached message, and also accept a
      // concurrently repaired deleted-coordinate window. Never claim coverage
      // merely from materialized neighboring rows.
      let hasUsableCache = try await database.reader.read { db in
        guard let chat = try Chat.getByPeerId(db: db, peerId: peer) else { return false }
        let window = try Self.aroundCache(db, chat: chat, anchorID: anchorID, limit: Int(windowLimit))
        return window.hasTarget || (window.hasWindow && !window.needsHistory)
      }
      try Task.checkCancellation()
      guard hasUsableCache else { throw error }
      return .notNeeded
    }
  }

  nonisolated static func aroundCache(
    _ db: Database,
    chat: Chat?,
    anchorID: Int64,
    limit: Int
  ) throws -> (hasTarget: Bool, hasWindow: Bool, needsHistory: Bool) {
    guard let chat else { return (false, false, true) }
    let query = Message.filter(Message.Columns.chatId == chat.id)
    let hasTarget = try query.filter(Message.Columns.messageId == anchorID).fetchCount(db) > 0

    let beforeLimit = max(60, limit) / 2
    let afterLimit = max(60, limit) - beforeLimit - (hasTarget ? 1 : 0)
    let older = try query
      .filter(Message.Columns.messageId > 0 && Message.Columns.messageId < anchorID)
      .select(Message.Columns.messageId)
      .order(Message.Columns.messageId.desc)
      .limit(beforeLimit)
      .asRequest(of: Int64.self).fetchAll(db)
    let newer = try query
      .filter(Message.Columns.messageId > anchorID)
      .select(Message.Columns.messageId)
      .order(Message.Columns.messageId.asc)
      .limit(afterLimit)
      .asRequest(of: Int64.self).fetchAll(db)

    let hasWindow = hasTarget || !older.isEmpty || !newer.isEmpty
    if !hasTarget {
      // A missing row is a valid deleted-message coordinate only when durable
      // coverage connects its nearest materialized neighbors through it.
      let lower = older.first ?? anchorID
      // Prefer the first newer row for deleted-target presentation. When none
      // is materialized, only certified tail coverage proves that older is the
      // correct fallback rather than a premature cached choice.
      let upper = newer.first ?? MessageHistoryHole.positiveMessageIDMax
      return (
        false,
        hasWindow,
        try MessageHistoryCoverageStore.intersects(
          db,
          chatId: chat.id,
          lowerId: min(lower, anchorID),
          upperId: max(upper, anchorID)
        )
      )
    }

    // Sparse search/reply rows do not prove that their neighbors are loaded.
    // A short side must be certified all the way to its absolute boundary.
    let lower = older.count == beforeLimit ? (older.last ?? anchorID) : 1
    // Chat.lastMsgId is a presentation summary, not proof that no newer
    // history exists. A short newer side is complete only when durable
    // coverage reaches the positive message-ID boundary.
    let upper = newer.count == afterLimit
      ? (newer.last ?? anchorID)
      : MessageHistoryHole.positiveMessageIDMax
    return (
      true,
      true,
      try MessageHistoryCoverageStore.intersects(
        db,
        chatId: chat.id,
        lowerId: lower,
        upperId: upper
      )
    )
  }

  public func loadOlder(peer: Peer, beforeID: Int64) async throws -> Outcome {
    guard beforeID > 1 else { return .notNeeded }
    return try await loadPage(peer: peer, boundaryID: beforeID, older: true)
  }

  public func loadNewer(peer: Peer, afterID: Int64) async throws -> Outcome {
    guard afterID > 0, afterID < MessageHistoryHole.positiveMessageIDMax else { return .notNeeded }
    return try await loadPage(peer: peer, boundaryID: afterID, older: false)
  }

  private func loadPage(peer: Peer, boundaryID: Int64, older: Bool) async throws -> Outcome {
    let chatID = try await resolveChatID(peer: peer)
    let request = PageRequest(chatID: chatID, boundaryID: boundaryID, older: older)
    if let task = pageTasks[request] {
      return try await task.value
    }

    let task = Task<Outcome, Error> { @MainActor in
      let needsRepair = try await AppDatabase.shared.reader.read { db in
        try MessageHistoryCoverageStore.intersects(
          db,
          chatId: chatID,
          lowerId: older ? 1 : boundaryID + 1,
          upperId: older ? boundaryID - 1 : MessageHistoryHole.positiveMessageIDMax
        )
      }
      guard needsRepair else { return .notNeeded }

      let rpcResult = try await Api.realtime.send(
        .getChatHistory(
          peer: peer,
          mode: older ? .historyModeOlder : .historyModeNewer,
          beforeID: older ? boundaryID : nil,
          afterID: older ? nil : boundaryID,
          limit: 100
        )
      )
      guard let rpcResult, case let .getChatHistory(result) = rpcResult else {
        throw RepairError.invalidResponse
      }
      return result.messages.isEmpty ? .empty : .loaded
    }
    pageTasks[request] = task
    defer { pageTasks[request] = nil }
    return try await task.value
  }

  private func resolveChatID(peer: Peer) async throws -> Int64 {
    switch peer {
      case let .thread(chatID):
        chatID
      case let .user(userID):
        try await AppDatabase.shared.reader.read { db in
          guard let chat = try Chat
            .filter(Chat.Columns.peerUserId == userID)
            .fetchOne(db)
          else { throw RepairError.unresolvedChat }
          return chat.id
        }
    }
  }
}
