import Foundation
import InlineProtocol
import Logger
import RealtimeV2

public struct DeleteBotTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/DeleteBot")

  public var method: InlineProtocol.Method = .deleteBot
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public let botUserId: Int64
  }

  public init(botUserId: Int64) {
    context = Context(botUserId: botUserId)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .deleteBot(.with {
      $0.botUserID = context.botUserId
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .deleteBot = result else {
      throw TransactionExecutionError.invalid
    }
    log.trace("deleteBot succeeded")
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
