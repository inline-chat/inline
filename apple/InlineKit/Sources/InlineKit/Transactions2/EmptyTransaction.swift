import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct EmptyTransaction: Transaction2 {
  // Properties
  public var method: InlineProtocol.Method = .getMe
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {}

  enum CodingKeys: String, CodingKey {
    case context
  }

  // Private
  private var log = Log.scoped("Transactions/Empty")

  public init() {
    context = Context()
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getMe(.init())
  }

  // MARK: - Transaction Methods

  public func optimistic() async {}

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .getMe(response) = result else {
      throw TransactionExecutionError.invalid
    }

    log.trace("getMe result: \(response)")

    // Apply to database/UI
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to get user info", error: error)
  }

  public func cancelled() async {
    log.debug("Cancelled empty transaction")
  }
}

// Helper

public extension Transaction2 where Self == EmptyTransaction {
  static func empty() -> EmptyTransaction {
    EmptyTransaction()
  }
}
