import Foundation
import InlineProtocol
import Logger
import RealtimeV2

public struct CreateBotTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/CreateBot")

  public var method: InlineProtocol.Method = .createBot
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public let name: String
    public let username: String
    public let addToSpace: Int64?
  }

  public init(name: String, username: String, addToSpace: Int64? = nil) {
    context = Context(name: name, username: username, addToSpace: addToSpace)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .createBot(.with {
      $0.name = context.name
      $0.username = context.username
      if let addToSpace = context.addToSpace {
        $0.addToSpace = addToSpace
      }
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .createBot(response) = result else {
      throw TransactionExecutionError.invalid
    }
    log.trace("createBot succeeded for botId: \(response.bot.id)")
  }

  public func failed(error: TransactionError2) async {
    log.error("CreateBot transaction failed", error: error)
  }
}

public extension Transaction2 where Self == CreateBotTransaction {
  static func createBot(
    name: String,
    username: String,
    addToSpace: Int64? = nil
  ) -> CreateBotTransaction {
    CreateBotTransaction(name: name, username: username, addToSpace: addToSpace)
  }
}
