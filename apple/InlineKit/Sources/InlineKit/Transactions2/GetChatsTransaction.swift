import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct GetChatsTransaction: Transaction2 {
  // Properties
  public var method: InlineProtocol.Method = .getChats
  public var context: Context

  public struct Context: Sendable, Codable {}

  enum CodingKeys: String, CodingKey {
    case context
  }

  // Private
  private var log = Log.scoped("Transactions/GetChats")

  public init() {
    context = Context()
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getChats(.init())
  }

  // MARK: - Transaction Methods

  public func apply(_ rpcResult: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .getChats(result) = rpcResult else {
      throw TransactionExecutionError.invalid
    }

    log.trace("getChats result: \(result)")

    // Apply to database/UI

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        // Save spaces
        for space in result.spaces {
          do {
            let spaceModel = Space(from: space)
            try spaceModel.save(db)
          } catch {
            Log.shared.error("Failed to save space", error: error)
          }
        }

        // Save users
        for user in result.users {
          do {
            _ = try User.save(db, user: user)
          } catch {
            Log.shared.error("Failed to save user", error: error)
          }
        }

        // First save chats without lastMsgId to avoid foreign key constraint
        var chatsToUpdate: [(Chat, Int64?)] = []
        for chat in result.chats {
          do {
            var chatModel = Chat(from: chat)
            let lastMsgId = chatModel.lastMsgId
            chatModel.lastMsgId = nil // Temporarily remove lastMsgId
            try chatModel.save(db)
            chatsToUpdate.append((chatModel, lastMsgId))
          } catch {
            Log.shared.error("Failed to save chat", error: error)
          }
        }

        // Save messages
        for message in result.messages {
          do {
            _ = try Message.save(db, protocolMessage: message, publishChanges: false)
          } catch {
            Log.shared.error("Failed to save message", error: error)
          }
        }

        // Now update chats with lastMsgId since messages exist
        for (chat, lastMsgId) in chatsToUpdate {
          do {
            var updatedChat = chat
            updatedChat.lastMsgId = lastMsgId
            try updatedChat.save(db)
          } catch {
            Log.shared.error("Failed to update chat with lastMsgId", error: error)
          }
        }

        // Save dialogs
        for dialog in result.dialogs {
          do {
            try dialog.saveFull(db)
          } catch {
            Log.shared.error("Failed to save dialog", error: error)
          }
        }
      }
    } catch {
      Log.shared.error("Failed to save chats", error: error)
      throw TransactionExecutionError.invalid
    }
  }
}

// Helper

public extension Transaction2 where Self == GetChatsTransaction {
  static func getChats() -> GetChatsTransaction {
    GetChatsTransaction()
  }
}
