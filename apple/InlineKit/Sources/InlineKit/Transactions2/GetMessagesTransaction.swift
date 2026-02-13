import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct GetMessagesTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/GetMessages")

  public var method: InlineProtocol.Method = .getMessages
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public var peer: Peer
    public var messageIds: [Int64]
  }

  public init(peer: Peer, messageIds: [Int64]) {
    context = Context(peer: peer, messageIds: messageIds)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getMessages(.with {
      $0.peerID = context.peer.toInputPeer()
      $0.messageIds = context.messageIds
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func optimistic() async {
    log.debug("GetMessages transaction - no optimistic updates")
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .getMessages(response) = result else {
      throw TransactionExecutionError.invalid
    }

    let peerId = context.peer

    do {
      _ = try await AppDatabase.shared.dbWriter.write { db in
        for message in response.messages {
          do {
            _ = try Message.save(db, protocolMessage: message, publishChanges: false)
          } catch {
            log.error("Failed to save message", error: error)
          }
        }
      }

      Task.detached(priority: .userInitiated) { @MainActor in
        MessagesPublisher.shared.messagesReload(peer: peerId, animated: false)
      }

      log.trace("getMessages saved")
    } catch {
      log.error("Failed to save getMessages results", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to get messages", error: error)
  }

  public func cancelled() async {
    log.debug("Cancelled getMessages transaction")
  }
}

// MARK: - Helper

public extension Transaction2 where Self == GetMessagesTransaction {
  static func getMessages(peer: Peer, messageIds: [Int64]) -> GetMessagesTransaction {
    GetMessagesTransaction(peer: peer, messageIds: messageIds)
  }
}
