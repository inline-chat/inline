import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct RemoveChatParticipantTransaction: Transaction2 {
  // Private
  private var log = Log.scoped("Transactions/RemoveChatParticipant")

  // Properties
  public var method: InlineProtocol.Method = .removeChatParticipant
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    let chatID: Int64
    let userID: Int64?
    let groupID: Int64?
  }

  public init(chatID: Int64, userID: Int64? = nil, groupID: Int64? = nil) {
    if chatID == 0 {
      log.error("chat ID is zero")
    }

    context = Context(chatID: chatID, userID: userID, groupID: groupID)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .removeChatParticipant(.with {
      $0.chatID = context.chatID
      if let userID = context.userID {
        $0.userID = userID
      }
      if let groupID = context.groupID {
        $0.groupID = groupID
      }
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // MARK: - Transaction Methods

  public func optimistic() async throws(TransactionExecutionError) {
    // Optimistic update: Remove participant from local database
    log.trace("Removing chat participant optimistically")

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        if let userID = context.userID {
          _ = try ChatParticipant
            .filter(ChatParticipant.Columns.chatId == context.chatID)
            .filter(ChatParticipant.Columns.userId == userID)
            .deleteAll(db)
        }

        if let groupID = context.groupID {
          _ = try ChatParticipantGroup
            .filter(ChatParticipantGroup.Columns.chatId == context.chatID)
            .filter(ChatParticipantGroup.Columns.groupId == groupID)
            .deleteAll(db)
        }
      }
    } catch {
      log.error("Failed to optimistically remove chat participant", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .removeChatParticipant = result else {
      throw TransactionExecutionError.invalid
    }

    log.trace("removeChatParticipant result confirmed")
    // The participant was already removed optimistically, no additional work needed
  }

  public func failed(error: TransactionError2) async {
    log.error("RemoveChatParticipant transaction failed, need to restore participant", error: error)
    // In a real implementation, we might want to restore the participant here
  }

  public func cancelled() async {
    log.trace("RemoveChatParticipant transaction cancelled")
  }
}

// MARK: - Helper

public extension Transaction2 where Self == RemoveChatParticipantTransaction {
  static func removeChatParticipant(chatID: Int64, userID: Int64) -> RemoveChatParticipantTransaction {
    RemoveChatParticipantTransaction(chatID: chatID, userID: userID)
  }

  static func removeChatParticipant(chatID: Int64, groupID: Int64) -> RemoveChatParticipantTransaction {
    RemoveChatParticipantTransaction(chatID: chatID, groupID: groupID)
  }
}
