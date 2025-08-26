import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct GetChatHistoryTransaction: Transaction2 {
  // Private
  private var log = Log.scoped("Transactions/GetChatHistory")

  // Properties
  public var method: InlineProtocol.Method = .getChatHistory
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public var peer: Peer
    public var offsetID: Int64?
    public var limit: Int32?
  }

  public init(peer: Peer, offsetID: Int64? = nil, limit: Int32? = nil) {
    context = Context(peer: peer, offsetID: offsetID, limit: limit)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getChatHistory(.with {
      $0.peerID = context.peer.toInputPeer()

      if let offsetID = context.offsetID {
        $0.offsetID = offsetID
      }

      if let limit = context.limit {
        $0.limit = limit
      }
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // MARK: - Transaction Methods

  public func optimistic() async {
    // GetChatHistory is a query transaction, no optimistic updates needed
    log.debug("GetChatHistory transaction - no optimistic updates")
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .getChatHistory(response) = result else {
      throw TransactionExecutionError.invalid
    }

    log.trace("getChatHistory result: \(response)")

    let peerId = context.peer

    do {
      _ = try await AppDatabase.shared.dbWriter.write { db in
        for message in response.messages {
          do {
            _ = try Message.save(db, protocolMessage: message, publishChanges: false) // we reload below
          } catch {
            log.error("Failed to save message", error: error)
          }
        }
      }

      // Publish and reload messages
      Task.detached(priority: .userInitiated) { @MainActor in
        MessagesPublisher.shared.messagesReload(peer: peerId, animated: false)
      }

      log.trace("getChatHistory saved")
    } catch {
      log.error("Failed to save chat history", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to get chat history", error: error)
  }

  public func cancelled() async {
    log.debug("Cancelled getChatHistory transaction")
  }
}

// MARK: - Helper

public extension Transaction2 where Self == GetChatHistoryTransaction {
  static func getChatHistory(
    peer: Peer,
    offsetID: Int64? = nil,
    limit: Int32? = nil
  ) -> GetChatHistoryTransaction {
    GetChatHistoryTransaction(peer: peer, offsetID: offsetID, limit: limit)
  }
}
