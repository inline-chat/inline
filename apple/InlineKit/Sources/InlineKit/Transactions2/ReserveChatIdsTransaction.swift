import Foundation
import InlineProtocol
import RealtimeV2

public struct ReserveChatIdsTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .reserveChatIds
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public var count: Int32
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public init(count: Int32) {
    context = Context(count: count)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .reserveChatIds(.with {
      $0.count = context.count
    })
  }

  public func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .reserveChatIds = rpcResult else {
      throw TransactionExecutionError.invalid
    }
  }
}

public extension Transaction2 where Self == ReserveChatIdsTransaction {
  static func reserveChatIds(count: Int32) -> ReserveChatIdsTransaction {
    ReserveChatIdsTransaction(count: count)
  }
}
