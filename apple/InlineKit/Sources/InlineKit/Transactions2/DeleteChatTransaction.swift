import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct DeleteChatTransaction: Transaction2 {
  // Private
  private var log = Log.scoped("Transactions/DeleteChat")
  // The persisted queue already belongs to one account. The transient lease
  // also fences a completion waiting on its writer during an account change.
  private var accountToken: AuthAccountMutationToken? = try? Auth.shared.handle.beginAccountMutation()

  // Properties
  public var method: InlineProtocol.Method = .deleteChat
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public var peerId: Peer
  }

  public init(peerId: Peer) {
    context = Context(peerId: peerId)
  }

  init(peerId: Peer, accountToken: AuthAccountMutationToken) {
    context = Context(peerId: peerId)
    self.accountToken = accountToken
  }

  public var executionKey: TransactionExecutionKey? {
    .peerMutation(context.peerId)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .deleteChat(.with {
      $0.peerID = context.peerId.toInputPeer()
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // MARK: - Transaction Methods

  public func optimistic() async {
    // A refused parent deletion must retain its children and their parent FK.
    // There is no reversible local mutation to make before server confirmation.
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard let accountToken, (try? Auth.shared.handle.validateAccountMutation(accountToken)) != nil else {
      throw TransactionExecutionError.invalid
    }
    try await apply(result, database: .shared, auth: Auth.shared.handle)
  }

  func apply(_ result: RpcResult.OneOf_Result?, database: AppDatabase, auth: AuthHandle,
             beforeWrite: @Sendable () -> Void = {}) async throws(TransactionExecutionError) {
    guard case .deleteChat = result, case let .thread(chatId) = context.peerId, let accountToken else {
      throw TransactionExecutionError.invalid
    }
    do {
      try auth.validateAccountMutation(accountToken)
      beforeWrite()
      try await database.dbWriter.write { db in
        try auth.validateAccountMutation(accountToken)
        // The empty RPC result and durable delete push confirm the same action.
        // The existing removal owner handles either arrival order and replay.
        try deleteLocalChatData(db, chatId: chatId)
      }
      try auth.validateAccountMutation(accountToken)
    } catch {
      log.error("Failed to apply confirmed chat deletion", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to delete chat", error: error)
  }

  public func cancelled() async { log.debug("Cancelled delete chat") }
}

// MARK: - Helper

public extension Transaction2 where Self == DeleteChatTransaction {
  static func deleteChat(peerId: Peer) -> DeleteChatTransaction {
    DeleteChatTransaction(peerId: peerId)
  }
}
