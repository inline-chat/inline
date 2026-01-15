import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct UpdateChatVisibilityTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/UpdateChatVisibility")

  public var method: InlineProtocol.Method = .updateChatVisibility
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    let chatID: Int64
    let isPublic: Bool
    let participantIDs: [Int64]
  }

  public init(chatID: Int64, isPublic: Bool, participantIDs: [Int64]) {
    if chatID == 0 {
      log.error("chat ID is zero")
    }

    context = Context(chatID: chatID, isPublic: isPublic, participantIDs: participantIDs)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .updateChatVisibility(.with {
      $0.chatID = context.chatID
      $0.isPublic = context.isPublic
      $0.participants = context.participantIDs.map { userId in
        InputChatParticipant.with { $0.userID = userId }
      }
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func optimistic() async throws(TransactionExecutionError) {
    log.trace("Updating chat visibility optimistically")

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        if var chat = try Chat.fetchOne(db, id: context.chatID) {
          chat.isPublic = context.isPublic
          try chat.save(db)
        }
      }
    } catch {
      log.error("Failed to update chat visibility optimistically", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .updateChatVisibility(response) = result else {
      throw TransactionExecutionError.invalid
    }

    log.trace("updateChatVisibility result: \(response)")

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        let chat = Chat(from: response.chat)
        try chat.save(db)
      }
    } catch {
      log.error("Failed to save updated chat visibility", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("UpdateChatVisibility transaction failed", error: error)
  }

  public func cancelled() async {
    log.trace("UpdateChatVisibility transaction cancelled")
  }
}

public extension Transaction2 where Self == UpdateChatVisibilityTransaction {
  static func updateChatVisibility(chatID: Int64, isPublic: Bool, participantIDs: [Int64]) -> UpdateChatVisibilityTransaction {
    UpdateChatVisibilityTransaction(chatID: chatID, isPublic: isPublic, participantIDs: participantIDs)
  }
}
