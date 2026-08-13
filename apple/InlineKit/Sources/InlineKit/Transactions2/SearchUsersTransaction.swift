import Foundation
import InlineProtocol
import RealtimeV2

public struct SearchUsersTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .searchUsers
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public let query: String
    public let limit: Int32
  }

  public init(query: String, limit: Int32 = 20) {
    context = Context(query: query, limit: limit)
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .searchUsers(.with {
      $0.query = context.query
      $0.limit = context.limit
    })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .searchUsers = result else {
      throw TransactionExecutionError.invalid
    }
  }
}

public extension Transaction2 where Self == SearchUsersTransaction {
  static func searchUsers(query: String, limit: Int32 = 20) -> SearchUsersTransaction {
    SearchUsersTransaction(query: query, limit: limit)
  }
}
