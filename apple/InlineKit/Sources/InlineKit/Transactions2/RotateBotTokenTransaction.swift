import Foundation
import InlineProtocol
import Logger
import RealtimeV2

public struct RotateBotTokenTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/RotateBotToken")

  public var method: InlineProtocol.Method = .rotateBotToken
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public let botUserId: Int64
  }

  public init(botUserId: Int64) {
    context = Context(botUserId: botUserId)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .rotateBotToken(.with {
      $0.botUserID = context.botUserId
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .rotateBotToken = result else {
      throw TransactionExecutionError.invalid
    }
    log.trace("rotateBotToken succeeded")
  }

  public func failed(error: TransactionError2) async {
    log.error("RotateBotToken transaction failed", error: error)
  }
}

public extension Transaction2 where Self == RotateBotTokenTransaction {
  static func rotateBotToken(botUserId: Int64) -> RotateBotTokenTransaction {
    RotateBotTokenTransaction(botUserId: botUserId)
  }
}

