import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct AddChatParticipantTransaction: Transaction2 {
  // Private
  private var log = Log.scoped("Transactions/AddChatParticipant")

  // Properties
  public var method: InlineProtocol.Method = .addChatParticipant
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    let chatID: Int64
    let userID: Int64
  }

  public init(chatID: Int64, userID: Int64) {
    if chatID == 0 {
      log.error("chat ID is zero")
    }

    context = Context(chatID: chatID, userID: userID)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .addChatParticipant(.with {
      $0.chatID = context.chatID
      $0.userID = context.userID
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // MARK: - Transaction Methods

  public func optimistic() async throws(TransactionExecutionError) {
    // Optimistic update: Add participant to UI
    // Note: This would require more UI integration to show the participant immediately
    log.trace("Adding chat participant optimistically")
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .addChatParticipant(response) = result else {
      throw TransactionExecutionError.invalid
    }

    log.trace("addChatParticipant result: \(response)")

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        try ChatParticipant.save(db, from: response.participant, chatId: context.chatID)
      }
      log.trace("addChatParticipant saved")
    } catch {
      log.error("Failed to save added chat participant", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("AddChatParticipant transaction failed", error: error)
  }

  public func cancelled() async {
    log.trace("AddChatParticipant transaction cancelled")
  }
}

// MARK: - Helper

public extension Transaction2 where Self == AddChatParticipantTransaction {
  static func addChatParticipant(chatID: Int64, userID: Int64) -> AddChatParticipantTransaction {
    AddChatParticipantTransaction(chatID: chatID, userID: userID)
  }
}
