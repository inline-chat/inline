import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct DeleteChatTransaction: Transaction2 {
  // Private
  private var log = Log.scoped("Transactions/DeleteChat")
  private var database: AppDatabase?
  private var auth: AuthHandle?
  private var accountToken: AuthAccountMutationToken?

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

  init(peerId: Peer, database: AppDatabase, auth: AuthHandle) {
    context = Context(peerId: peerId)
    self.database = database
    self.auth = auth
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

  public func preparingForDispatch() async throws(TransactionExecutionError) -> any Transaction2 {
    do {
      var prepared = self
      let auth = auth ?? Auth.shared.handle
      prepared.accountToken = try auth.beginAccountMutation()
      prepared.auth = auth
      prepared.database = database ?? AppDatabase.shared
      return prepared
    } catch {
      log.error("Failed to prepare chat deletion", error: error)
      throw .invalid
    }
  }

  /// Deleting the chat cascades into its cached messages and history. Preserve
  /// those rows until the server confirms rather than attempting a partial rollback.
  public func optimistic() async {}

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .deleteChat = result,
          let database, let auth, let accountToken
    else {
      throw TransactionExecutionError.invalid
    }

    do {
      try await Chat.deleteFromLocalDatabase(
        peerId: context.peerId,
        databaseWriter: database.dbWriter,
        auth: auth,
        accountToken: accountToken
      )
    } catch {
      log.error("Failed to apply confirmed chat deletion", error: error)
      throw .invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to delete chat", error: error)
  }
}

// MARK: - Helper

public extension Transaction2 where Self == DeleteChatTransaction {
  static func deleteChat(peerId: Peer) -> DeleteChatTransaction {
    DeleteChatTransaction(peerId: peerId)
  }
}
