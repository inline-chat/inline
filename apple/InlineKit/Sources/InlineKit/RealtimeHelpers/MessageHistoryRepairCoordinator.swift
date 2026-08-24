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

  private struct OlderRequest: Hashable {
    let chatID: Int64
    let beforeID: Int64
  }

  private var olderTasks: [OlderRequest: Task<Outcome, Error>] = [:]

  private init() {}

  public func loadOlder(peer: Peer, beforeID: Int64) async throws -> Outcome {
    guard beforeID > 1 else { return .notNeeded }
    let chatID = try await resolveChatID(peer: peer)
    let request = OlderRequest(chatID: chatID, beforeID: beforeID)
    if let task = olderTasks[request] {
      return try await task.value
    }

    let task = Task<Outcome, Error> { @MainActor in
      let needsRepair = try await AppDatabase.shared.reader.read { db in
        try MessageHistoryCoverageStore.intersects(
          db,
          chatId: chatID,
          lowerId: 1,
          upperId: beforeID - 1
        )
      }
      guard needsRepair else { return .notNeeded }

      let rpcResult = try await Api.realtime.send(
        .getChatHistory(
          peer: peer,
          mode: .historyModeOlder,
          beforeID: beforeID,
          limit: 100
        )
      )
      guard let rpcResult, case let .getChatHistory(result) = rpcResult else {
        throw RepairError.invalidResponse
      }
      return result.messages.isEmpty ? .empty : .loaded
    }
    olderTasks[request] = task
    defer { olderTasks[request] = nil }
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
