import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct SearchMessagesTransaction: Transaction2 {
  // Private
  private var log = Log.scoped("Transactions/SearchMessages")

  // Properties
  public var method: InlineProtocol.Method = .searchMessages
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public var peer: Peer
    public var queries: [String]
    public var offsetID: Int64?
    public var limit: Int32?
    public var filter: InlineProtocol.SearchMessagesFilter?
  }

  public init(
    peer: Peer,
    queries: [String],
    offsetID: Int64? = nil,
    limit: Int32? = nil,
    filter: InlineProtocol.SearchMessagesFilter? = nil
  ) {
    context = Context(peer: peer, queries: queries, offsetID: offsetID, limit: limit, filter: filter)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .searchMessages(.with {
      $0.peerID = context.peer.toInputPeer()
      $0.queries = context.queries

      if let offsetID = context.offsetID {
        $0.offsetID = offsetID
      }

      if let limit = context.limit {
        $0.limit = limit
      }

      if let filter = context.filter {
        $0.filter = filter
      }
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // MARK: - Transaction Methods

  public func optimistic() async {
    log.debug("SearchMessages transaction - no optimistic updates")
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .searchMessages(response) = result else {
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

      log.trace("searchMessages saved")
    } catch {
      log.error("Failed to save search messages", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to search messages", error: error)
  }

  public func cancelled() async {
    log.debug("Cancelled search messages transaction")
  }
}

// MARK: - Helper

public extension Transaction2 where Self == SearchMessagesTransaction {
  static func searchMessages(
    peer: Peer,
    queries: [String],
    offsetID: Int64? = nil,
    limit: Int32? = nil,
    filter: InlineProtocol.SearchMessagesFilter? = nil
  ) -> SearchMessagesTransaction {
    SearchMessagesTransaction(
      peer: peer,
      queries: queries,
      offsetID: offsetID,
      limit: limit,
      filter: filter
    )
  }
}
