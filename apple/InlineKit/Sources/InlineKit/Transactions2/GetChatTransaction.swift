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
          var chat = Chat(from: response.chat)
          try clearMissingOptionalReferences(in: &chat, db: db)
          try chat.saveWithValidLastMsg(db)
        } catch {
          log.error("Failed to save chat", error: error)
          throw error
        }

        do {
          _ = try response.dialog.saveFull(db)
        } catch {
          log.error("Failed to save dialog", error: error)
          throw error
        }

        if response.hasAnchorMessage {
          do {
            _ = try Message.save(db, protocolMessage: response.anchorMessage, publishChanges: false)
          } catch {
            log.warning("Skipping anchor message for getChat result because it could not be saved: \(error)")
          }
        }

        do {
          let chatId = response.chat.id
          try PinnedMessage.replaceAll(db, chatId: chatId, messageIds: response.pinnedMessageIds)
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

  private func clearMissingOptionalReferences(in chat: inout Chat, db: Database) throws {
    if let spaceId = chat.spaceId, try Space.fetchOne(db, id: spaceId) == nil {
      log.warning("Dropping missing space reference while saving getChat result for chat \(chat.id)")
      chat.spaceId = nil
    }

    if let createdBy = chat.createdBy, try User.fetchOne(db, id: createdBy) == nil {
      log.warning("Dropping missing creator reference while saving getChat result for chat \(chat.id)")
      chat.createdBy = nil
    }

    if let parentChatId = chat.parentChatId, try Chat.fetchOne(db, id: parentChatId) == nil {
      log.warning("Dropping missing parent chat reference while saving getChat result for chat \(chat.id)")
      chat.parentChatId = nil
    }
  }
}

// MARK: - Helper

public extension Transaction2 where Self == GetChatTransaction {
  static func getChat(peer: Peer) -> GetChatTransaction {
    GetChatTransaction(peer: peer)
  }
}
