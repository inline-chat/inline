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
    guard anchorID > 0 else { throw RepairError.invalidResponse }
    let windowLimit = Int32(clamping: max(60, limit))
    let cached = try await database.reader.read { db in
      let chat = try Chat.getByPeerId(db: db, peerId: peer)
      let window = try Self.aroundCache(db, chat: chat, anchorID: anchorID, limit: Int(windowLimit))
      return (hasChat: chat != nil, hasTarget: window.hasTarget, needsHistory: window.needsHistory)
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
      return result.messages.contains(where: { $0.id == anchorID }) ? .loaded : .empty
    } catch {
      try Task.checkCancellation()
      // Preserve offline jumps to a cached message even if its surrounding
      // history cannot be repaired. Never claim new coverage for this fallback.
      let hasCachedTarget = try await database.reader.read { db in
        guard let chat = try Chat.getByPeerId(db: db, peerId: peer) else { return false }
        return try Message
          .filter(Message.Columns.chatId == chat.id && Message.Columns.messageId == anchorID)
          .fetchCount(db) > 0
      }
      try Task.checkCancellation()
      guard hasCachedTarget else { throw error }
      return .notNeeded
    }
  }

  nonisolated static func aroundCache(
    _ db: Database,
    chat: Chat?,
    anchorID: Int64,
    limit: Int
  ) throws -> (hasTarget: Bool, needsHistory: Bool) {
    guard let chat else { return (false, true) }
    let query = Message.filter(Message.Columns.chatId == chat.id)
    guard try query.filter(Message.Columns.messageId == anchorID).fetchCount(db) > 0 else { return (false, true) }

    let beforeLimit = max(60, limit) / 2
    let afterLimit = max(60, limit) - beforeLimit - 1
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

    // Sparse search/reply rows do not prove that their neighbors are loaded.
    // If a side has too few rows, include its known boundary in the coverage check.
    let lower = older.count == beforeLimit ? (older.last ?? anchorID) : 1
    let knownTail = max(anchorID, max(chat.lastMsgId ?? anchorID, newer.last ?? anchorID))
    let upper = newer.count == afterLimit ? (newer.last ?? anchorID) : knownTail
    return (true, try MessageHistoryCoverageStore.intersects(db, chatId: chat.id, lowerId: lower, upperId: upper))
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
