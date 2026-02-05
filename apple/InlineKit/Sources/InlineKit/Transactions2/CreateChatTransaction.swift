import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct CreateChatTransaction: Transaction2 {
  // Properties
  public var method: InlineProtocol.Method = .createChat
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public var title: String
    public var emoji: String?
    public var isPublic: Bool
    public var spaceId: Int64?
    public var participants: [Int64]
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  private var log = Log.scoped("Transactions/CreateChat")

  public init(title: String, emoji: String?, isPublic: Bool, spaceId: Int64?, participants: [Int64]) {
    context = Context(title: title, emoji: emoji, isPublic: isPublic, spaceId: spaceId, participants: participants)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .createChat(.with {
      $0.title = context.title
      if let spaceId = context.spaceId { $0.spaceID = spaceId }
      if let emoji = context.emoji { $0.emoji = emoji }
      $0.isPublic = context.isPublic
      $0.participants = context.participants.map { userId in
        InputChatParticipant.with { $0.userID = Int64(userId) }
      }
    })
  }

  // Methods
  public func apply(_ result: RpcResult.OneOf_Result?) async throws(
    TransactionExecutionError
  ) {
    guard case let .createChat(response) = result else {
      throw TransactionExecutionError.invalid
    }

    do {
      // Save chat and dialog to database
      try await AppDatabase.shared.dbWriter.write { db in
        do {
          let chat = Chat(from: response.chat)
          try chat.save(db)
        } catch {
          log.error("Failed to save chat", error: error)
        }

        do {
          let dialog = Dialog(from: response.dialog)
          try dialog.save(db)
        } catch {
          log.error("Failed to save dialog", error: error)
        }
      }
    } catch {
      log.error("Failed to save chat in transaction", error: error)
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to create chat", error: error)
  }
}

// Helper

public extension Transaction2 where Self == CreateChatTransaction {
  static func createChat(
    title: String,
    emoji: String?,
    isPublic: Bool,
    spaceId: Int64?,
    participants: [Int64]
  ) -> CreateChatTransaction {
    CreateChatTransaction(title: title, emoji: emoji, isPublic: isPublic, spaceId: spaceId, participants: participants)
  }
}
