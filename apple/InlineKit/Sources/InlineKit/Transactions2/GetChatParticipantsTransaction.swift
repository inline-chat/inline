import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct GetChatParticipantsTransaction: Transaction2 {
  // Private
  private var log = Log.scoped("Transactions/GetChatParticipants")

  // Properties
  public var method: InlineProtocol.Method = .getChatParticipants
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    let chatID: Int64
  }

  public init(chatID: Int64) {
    context = Context(chatID: chatID)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getChatParticipants(.with { $0.chatID = context.chatID })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // MARK: - Transaction Methods

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .getChatParticipants(response) = result else {
      throw TransactionExecutionError.invalid
    }

    log.trace("getChatParticipants result: \(response)")

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        // Save users
        for user in response.users {
          do {
            _ = try User.save(db, user: user)
          } catch {
            log.error("Failed to save user", error: error)
          }
        }

        // Save participants
        for participant in response.participants {
          do {
            ChatParticipant.save(db, from: participant, chatId: context.chatID)
          } catch {
            log.error("Failed to save chat participant", error: error)
          }
        }
      }
      log.trace("getChatParticipants saved")
    } catch {
      log.error("Failed to save chat participants", error: error)
      throw TransactionExecutionError.invalid
    }
  }
}

// MARK: - Helper

public extension Transaction2 where Self == GetChatParticipantsTransaction {
  static func getChatParticipants(chatID: Int64) -> GetChatParticipantsTransaction {
    GetChatParticipantsTransaction(chatID: chatID)
  }
}
