import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct JoinPublicSpaceTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .joinPublicSpace
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public let handle: String
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  private var log = Log.scoped("Transactions/JoinPublicSpace")

  public init(handle: String) {
    context = Context(handle: handle)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .joinPublicSpace(.with { $0.handle = context.handle })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .joinPublicSpace(response) = result else {
      throw TransactionExecutionError.invalid
    }

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        try Space(from: response.space).save(db)
        try Member(from: response.member).save(db)
      }
    } catch {
      log.error("Failed to save joined public space", error: error)
      throw TransactionExecutionError.invalid
    }
  }
}

public extension Transaction2 where Self == JoinPublicSpaceTransaction {
  static func joinPublicSpace(handle: String) -> JoinPublicSpaceTransaction {
    JoinPublicSpaceTransaction(handle: handle)
  }
}
