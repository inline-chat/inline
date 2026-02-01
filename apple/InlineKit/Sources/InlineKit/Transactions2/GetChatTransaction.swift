import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct GetChatTransaction: Transaction2 {
  // Private
  private var log = Log.scoped("Transactions/GetChat")

  // Properties
  public var method: InlineProtocol.Method = .getChat
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public var peer: Peer
  }

  public init(peer: Peer) {
    context = Context(peer: peer)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getChat(.with {
      $0.peerID = context.peer.toInputPeer()
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // MARK: - Transaction Methods

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .getChat(response) = result else {
      throw TransactionExecutionError.invalid
    }

    log.trace("getChat result: \(response)")

    guard response.hasChat, response.hasDialog else {
      log.error("getChat result missing chat or dialog")
      throw TransactionExecutionError.invalid
    }

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        do {
          let chat = Chat(from: response.chat)
          try chat.save(db)
        } catch {
          log.error("Failed to save chat", error: error)
          throw error
        }

        do {
          let dialog = Dialog(from: response.dialog)
          try dialog.save(db)
        } catch {
          log.error("Failed to save dialog", error: error)
          throw error
        }

        do {
          let chatId = response.chat.id
          try PinnedMessage.filter(Column("chatId") == chatId).deleteAll(db)

          if !response.pinnedMessageIds.isEmpty {
            for (index, messageId) in response.pinnedMessageIds.enumerated() {
              let pinned = PinnedMessage(chatId: chatId, messageId: messageId, position: Int64(index))
              try pinned.save(db)
            }
          }
        } catch {
          log.error("Failed to save pinned messages", error: error)
          throw error
        }
      }
      log.trace("getChat saved")
    } catch {
      log.error("Failed to save chat/dialog in transaction", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to get chat", error: error)
  }
}

// MARK: - Helper

public extension Transaction2 where Self == GetChatTransaction {
  static func getChat(peer: Peer) -> GetChatTransaction {
    GetChatTransaction(peer: peer)
  }
}
