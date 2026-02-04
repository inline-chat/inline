import Foundation
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
