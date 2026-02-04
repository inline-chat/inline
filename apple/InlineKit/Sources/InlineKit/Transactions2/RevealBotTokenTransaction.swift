import Foundation
import InlineProtocol
import Logger
import RealtimeV2

public struct RevealBotTokenTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/RevealBotToken")

  public var method: InlineProtocol.Method = .revealBotToken
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public let botUserId: Int64
  }

  public init(botUserId: Int64) {
    context = Context(botUserId: botUserId)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .revealBotToken(.with {
      $0.botUserID = context.botUserId
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .revealBotToken = result else {
      throw TransactionExecutionError.invalid
    }
    log.trace("revealBotToken succeeded")
  }

  public func failed(error: TransactionError2) async {
    log.error("RevealBotToken transaction failed", error: error)
  }
}

public extension Transaction2 where Self == RevealBotTokenTransaction {
  static func revealBotToken(botUserId: Int64) -> RevealBotTokenTransaction {
    RevealBotTokenTransaction(botUserId: botUserId)
  }
}
