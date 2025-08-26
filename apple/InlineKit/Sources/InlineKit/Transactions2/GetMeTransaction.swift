import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct GetMeTransaction: Transaction2 {
  // Private
  private var log = Log.scoped("Transactions/GetMe")

  // Properties
  public var method: InlineProtocol.Method = .getMe
  public var context: Context = .init()
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {}

  public init() {}

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getMe(.init())
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // MARK: - Transaction Methods

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .getMe(response) = result else {
      throw TransactionExecutionError.invalid
    }

    log.trace("getMe result: \(response)")
    guard response.hasUser else { return }

    do {
      _ = try await AppDatabase.shared.dbWriter.write { db in
        try User.save(db, user: response.user)
      }
      log.trace("getMe saved")
    } catch {
      log.error("Failed to save user from getMe", error: error)
      throw TransactionExecutionError.invalid
    }
  }
}

// MARK: - Helper

public extension Transaction2 where Self == GetMeTransaction {
  static func getMe() -> GetMeTransaction {
    GetMeTransaction()
  }
}
