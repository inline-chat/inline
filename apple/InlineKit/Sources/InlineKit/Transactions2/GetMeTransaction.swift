import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct GetMeTransaction: Transaction2 {
  // Properties
  public var method: InlineProtocol.Method = .getMe
  public var input: InlineProtocol.RpcCall.OneOf_Input?

  // Private
  private var log = Log.scoped("Transactions/GetMe")

  public init() {
    // Create input for getMe
    input = .getMe(.init())
  }

  // MARK: - Transaction Methods

  public func optimistic() async {
    // GetMe is a query transaction, no optimistic updates needed
    log.debug("GetMe transaction - no optimistic updates")
  }

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

  public func failed(error: TransactionError2) async {
    log.error("Failed to get user info", error: error)
  }

  public func cancelled() async {
    log.debug("Cancelled getMe transaction")
  }
}

// MARK: - Codable

extension GetMeTransaction: Codable {
  // MARK: - Encoding

  public func encode(to encoder: Encoder) throws {
    // No additional properties to encode beyond what the protocol requires
    // The transaction can be fully reconstructed from its type
  }

  // MARK: - Decoding

  public init(from decoder: Decoder) throws {
    // Reconstruct the transaction
    method = .getMe
    input = .getMe(.init())
  }
}

// MARK: - Helper

public extension Transaction2 where Self == GetMeTransaction {
  static func getMe() -> GetMeTransaction {
    GetMeTransaction()
  }
}
