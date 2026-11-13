import Auth
import Foundation
import InlineProtocol
import Logger
import RealtimeV2

public struct DeleteBotTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/DeleteBot")
  private var database: AppDatabase?
  private var auth: AuthHandle?
  private var accountToken: AuthAccountMutationToken?

  public var method: InlineProtocol.Method = .deleteBot
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public let botUserId: Int64
  }

  public init(botUserId: Int64) {
    context = Context(botUserId: botUserId)
  }

  init(botUserId: Int64, database: AppDatabase, auth: AuthHandle) {
    context = Context(botUserId: botUserId)
    self.database = database
    self.auth = auth
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .deleteBot(.with {
      $0.botUserID = context.botUserId
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func preparingForDispatch() async throws(TransactionExecutionError) -> any Transaction2 {
    do {
      var prepared = self
      let auth = auth ?? Auth.shared.handle
      prepared.accountToken = try auth.beginAccountMutation()
      prepared.auth = auth
      prepared.database = database ?? AppDatabase.shared
      return prepared
    } catch {
      log.error("Failed to prepare bot deletion", error: error)
      throw .invalid
    }
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .deleteBot = result else {
      throw TransactionExecutionError.invalid
    }
    log.trace("deleteBot succeeded")
    // The server keeps no usable DM with a deleted bot. Drop the cached one so the
    // bot stops appearing in the sidebar and as a direct-chat mention candidate.
    if let database, let auth, let accountToken {
      do {
        try await Chat.deleteFromLocalDatabase(
          peerId: .user(id: context.botUserId),
          databaseWriter: database.dbWriter,
          auth: auth,
          accountToken: accountToken
        )
      } catch {
        log.error("Failed to remove the deleted bot's chat locally", error: error)
      }
    }
    // A deleted bot is nobody's to mention anymore.
    do {
      try await (database ?? AppDatabase.shared).dbWriter.write { db in
        try BotOwner.remove(db, botUserId: context.botUserId)
      }
    } catch {
      log.error("Failed to clear the deleted bot's owner locally", error: error)
    }
    NotificationCenter.default.post(name: .botAgentsChanged, object: context.botUserId)
  }

  public func failed(error: TransactionError2) async {
    log.error("DeleteBot transaction failed", error: error)
  }
}

public extension Transaction2 where Self == DeleteBotTransaction {
  static func deleteBot(botUserId: Int64) -> DeleteBotTransaction {
    DeleteBotTransaction(botUserId: botUserId)
  }
}
