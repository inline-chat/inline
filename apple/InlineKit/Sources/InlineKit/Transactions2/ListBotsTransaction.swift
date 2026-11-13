import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct ListBotsTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/ListBots")

  public var method: InlineProtocol.Method = .listBots
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public init() {}
  }

  public init() {
    context = Context()
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .listBots(.with { _ in })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .listBots(response) = result else {
      throw TransactionExecutionError.invalid
    }

    log.trace("listBots result count: \(response.bots.count)")
    guard let ownerUserId = Auth.shared.getCurrentUserId() else { return }
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        try Self.saveOwnedBots(response.bots, ownerUserId: ownerUserId, in: db)
      }
    } catch {
      log.error("Failed to save listed bots", error: error)
    }
  }

  /// The list is the complete set of the owner's bots: save each one and drop
  /// ownership from any local bot that is no longer in it.
  static func saveOwnedBots(_ bots: [InlineProtocol.User], ownerUserId: Int64, in db: Database) throws {
    var ids: [Int64] = []
    for bot in bots where bot.id > 0 {
      ids.append(bot.id)
      // Listing runs on every app activation; leave unchanged rows alone so
      // their observers don't fire.
      let listed = User(from: bot)
      if let saved = try User.fetchOne(db, id: bot.id),
         saved.bot,
         saved.firstName == listed.firstName,
         saved.lastName == listed.lastName,
         saved.username == listed.username,
         saved.pendingSetup == listed.pendingSetup,
         saved.profileFileUniqueId == listed.profileFileUniqueId
      {
        continue
      }
      _ = try User.save(db, user: bot)
    }
    try BotOwner.replaceOwnedBots(db, botUserIds: ids, ownerUserId: ownerUserId)
  }

  public func failed(error: TransactionError2) async {
    log.error("ListBots transaction failed", error: error)
  }
}

public extension Transaction2 where Self == ListBotsTransaction {
  static func listBots() -> ListBotsTransaction {
    ListBotsTransaction()
  }
}
